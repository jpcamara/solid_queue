# The tables and functions DatabaseAdapters::PostgresqlWithSemaphoreLog keeps
# semaphores in, on PostgreSQL 12 or later. Schema dumps in Ruby leave out
# partitioned tables and functions, so the queue database needs
# schema_format :sql.
#
# A semaphore is the newest row of its key in solid_queue_semaphore_log, until
# that row expires. Taking or giving back a slot inserts a row; nothing is
# updated or deleted. Callers on a key take turns through an advisory lock on
# it, held until their transaction ends. The log is three partitions, and
# periods of ten minutes take turns writing to them. The dispatcher's
# concurrency maintenance copies what's still live out of the partition written
# to two periods ago and truncates it.
class CreateSolidQueueSemaphoreLog < ActiveRecord::Migration[7.1]
  def up
    execute <<~SQL
      CREATE SEQUENCE solid_queue_semaphore_log_id_seq;

      CREATE TABLE solid_queue_semaphore_log (
        id bigint NOT NULL,
        part smallint NOT NULL,
        key varchar NOT NULL,
        semaphore_id bigint NOT NULL, -- the id of the row that created the semaphore
        value integer NOT NULL,
        expires_at timestamp(6) NOT NULL,
        created_at timestamp(6) NOT NULL
      ) PARTITION BY LIST (part);

      CREATE TABLE solid_queue_semaphore_log_0 PARTITION OF solid_queue_semaphore_log FOR VALUES IN (0);
      CREATE TABLE solid_queue_semaphore_log_1 PARTITION OF solid_queue_semaphore_log FOR VALUES IN (1);
      CREATE TABLE solid_queue_semaphore_log_2 PARTITION OF solid_queue_semaphore_log FOR VALUES IN (2);

      -- A key's newest row is the first one read going backwards
      CREATE INDEX index_solid_queue_semaphore_log_on_key_and_id ON solid_queue_semaphore_log (key, id);

      -- The partition written to now
      CREATE FUNCTION solid_queue_semaphore_log_part() RETURNS smallint LANGUAGE sql STABLE AS $$
        SELECT (floor(extract(epoch FROM statement_timestamp()) / 600)::bigint % 3)::smallint
      $$;

      -- Waits for the key's turn, until the transaction ends. What's read after it is only up to date
      -- under READ COMMITTED, where each statement sees what was committed before it started; a
      -- REPEATABLE READ or SERIALIZABLE transaction would still see the state from its start.
      CREATE FUNCTION solid_queue_semaphore_log_lock(i_key varchar) RETURNS void LANGUAGE plpgsql AS $$
      BEGIN
        IF current_setting('transaction_isolation') <> 'read committed' THEN
          RAISE EXCEPTION 'Solid Queue''s semaphore log needs READ COMMITTED, not %', upper(current_setting('transaction_isolation'))
            USING ERRCODE = 'feature_not_supported';
        END IF;
        PERFORM pg_advisory_xact_lock(hashtextextended('solid_queue_semaphore_log/' || i_key, 0));
      END $$;

      -- The key's semaphore: its newest row, or null if there's none or it has expired.
      -- Read after the key's lock is taken, so it sees what the last holder committed.
      CREATE FUNCTION solid_queue_semaphore_log_current(i_key varchar, i_now timestamp)
      RETURNS solid_queue_semaphore_log LANGUAGE plpgsql STABLE AS $$
      DECLARE
        s solid_queue_semaphore_log;
      BEGIN
        SELECT * INTO s FROM solid_queue_semaphore_log WHERE key = i_key ORDER BY id DESC LIMIT 1;
        IF FOUND AND s.expires_at > i_now THEN
          RETURN s;
        END IF;
        RETURN NULL;
      END $$;

      -- Inserts the key's new state. Returns the semaphore's id: i_semaphore_id, or the new row's
      -- when it's null, for a semaphore created by this row.
      CREATE FUNCTION solid_queue_semaphore_log_append(i_key varchar, i_semaphore_id bigint, i_value integer, i_expires_at timestamp, i_now timestamp)
      RETURNS bigint LANGUAGE plpgsql AS $$
      DECLARE
        v_id bigint := nextval('solid_queue_semaphore_log_id_seq');
      BEGIN
        INSERT INTO solid_queue_semaphore_log (id, part, key, semaphore_id, value, expires_at, created_at)
        VALUES (v_id, solid_queue_semaphore_log_part(), i_key, coalesce(i_semaphore_id, v_id), i_value, i_expires_at, i_now);
        RETURN coalesce(i_semaphore_id, v_id);
      END $$;

      -- Takes a slot, as Semaphore.wait does: creates the semaphore with the rest of the limit, or
      -- takes one from it if any is left. Returns the semaphore's id, or null if none was free.
      CREATE FUNCTION solid_queue_semaphore_wait(i_key varchar, i_limit integer, i_expires_at timestamp, i_now timestamp)
      RETURNS bigint LANGUAGE plpgsql AS $$
      DECLARE
        s solid_queue_semaphore_log;
      BEGIN
        PERFORM solid_queue_semaphore_log_lock(i_key);
        s := solid_queue_semaphore_log_current(i_key, i_now);
        IF s.id IS NULL THEN
          RETURN solid_queue_semaphore_log_append(i_key, NULL, i_limit - 1, i_expires_at, i_now);
        ELSIF s.value > 0 THEN
          RETURN solid_queue_semaphore_log_append(i_key, s.semaphore_id, s.value - 1, i_expires_at, i_now);
        END IF;
        RETURN NULL;
      END $$;

      -- Takes up to n slots for each key in i_wanted (key, n, limit, expires_at), by key in byte
      -- order, as single jobs are dispatched. Returns the semaphore's id and how many it gave, by key.
      CREATE FUNCTION solid_queue_semaphore_wait_all(i_wanted json, i_now timestamp)
      RETURNS TABLE (o_key varchar, o_semaphore_id bigint, o_taken integer) LANGUAGE plpgsql AS $$
      DECLARE
        w record;
        s solid_queue_semaphore_log;
      BEGIN
        FOR w IN SELECT * FROM json_to_recordset(i_wanted) AS x(key varchar, n integer, "limit" integer, expires_at timestamp) ORDER BY x.key COLLATE "C" LOOP
          PERFORM solid_queue_semaphore_log_lock(w.key);
          s := solid_queue_semaphore_log_current(w.key, i_now);
          o_key := w.key;
          IF s.id IS NULL THEN
            o_taken := least(w.n, w."limit");
            o_semaphore_id := solid_queue_semaphore_log_append(w.key, NULL, w."limit" - o_taken, w.expires_at, i_now);
          ELSE
            o_taken := least(w.n, greatest(s.value, 0));
            o_semaphore_id := s.semaphore_id;
            IF o_taken > 0 THEN
              PERFORM solid_queue_semaphore_log_append(w.key, s.semaphore_id, s.value - o_taken, w.expires_at, i_now);
            END IF;
          END IF;
          RETURN NEXT;
        END LOOP;
      END $$;

      -- Whether the job's semaphore is still the one of its key and isn't below zero. Takes the
      -- key's lock. A null i_semaphore_id, for jobs that didn't record theirs, matches any.
      CREATE FUNCTION solid_queue_semaphore_held(i_key varchar, i_semaphore_id bigint, i_now timestamp)
      RETURNS boolean LANGUAGE plpgsql AS $$
      DECLARE
        s solid_queue_semaphore_log;
      BEGIN
        PERFORM solid_queue_semaphore_log_lock(i_key);
        s := solid_queue_semaphore_log_current(i_key, i_now);
        RETURN s.id IS NOT NULL AND (i_semaphore_id IS NULL OR s.semaphore_id = i_semaphore_id) AND s.value >= 0;
      END $$;

      -- Gives the job's slot back, as Semaphore.signal does, to the semaphore it came from, unless
      -- that's full; with i_handed_over, the slot stays taken, for the job it's handed to. Returns
      -- the semaphore's id, or null if the slot wasn't given back.
      CREATE FUNCTION solid_queue_semaphore_signal(i_key varchar, i_semaphore_id bigint, i_limit integer, i_expires_at timestamp, i_now timestamp,
                                                   i_handed_over boolean DEFAULT false)
      RETURNS bigint LANGUAGE plpgsql AS $$
      DECLARE
        s solid_queue_semaphore_log;
      BEGIN
        PERFORM solid_queue_semaphore_log_lock(i_key);
        s := solid_queue_semaphore_log_current(i_key, i_now);
        IF s.id IS NOT NULL AND (i_semaphore_id IS NULL OR s.semaphore_id = i_semaphore_id) AND s.value < i_limit THEN
          RETURN solid_queue_semaphore_log_append(i_key, s.semaphore_id, s.value + CASE WHEN i_handed_over THEN 0 ELSE 1 END, i_expires_at, i_now);
        END IF;
        RETURN NULL;
      END $$;

      -- Copies the newest row of each key out of the partition written to two periods ago, if it's
      -- still the key's newest and hasn't expired, and truncates that partition. Returns how many
      -- rows it copied, or null if another rotation is running or the partition stayed in use.
      -- Every query on the log reads all three partitions, so the lock the truncate needs waits for
      -- every transaction that read the log, and new ones wait behind it. It's tried briefly a few
      -- times, and left for the next maintenance run if it's not got.
      CREATE FUNCTION solid_queue_semaphore_log_rotate(i_now timestamp) RETURNS integer LANGUAGE plpgsql AS $$
      DECLARE
        v_part smallint := solid_queue_semaphore_log_part();
        v_table text := 'solid_queue_semaphore_log_' || ((v_part + 1) % 3);
        v_lock_timeout text := current_setting('lock_timeout');
        v_locked boolean := false;
        v_used boolean;
        v_copied integer;
      BEGIN
        IF NOT pg_try_advisory_xact_lock(hashtextextended('solid_queue_semaphore_log_rotate', 0)) THEN
          RETURN NULL;
        END IF;
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I)', v_table) INTO v_used;
        IF NOT v_used THEN
          RETURN 0;
        END IF;
        FOR attempt IN 1..5 LOOP
          BEGIN
            PERFORM set_config('lock_timeout', '20ms', true);
            EXECUTE format('LOCK TABLE %I IN ACCESS EXCLUSIVE MODE', v_table);
            v_locked := true;
            EXIT;
          EXCEPTION WHEN lock_not_available THEN
            PERFORM pg_sleep(0.02);
          END;
        END LOOP;
        PERFORM set_config('lock_timeout', v_lock_timeout, true);
        IF NOT v_locked THEN
          RETURN NULL;
        END IF;
        EXECUTE format(
          'INSERT INTO solid_queue_semaphore_log (id, part, key, semaphore_id, value, expires_at, created_at)
           SELECT s.id, $1, s.key, s.semaphore_id, s.value, s.expires_at, s.created_at
           FROM (SELECT DISTINCT ON (key) * FROM %I ORDER BY key, id DESC) s
           WHERE s.expires_at > $2 AND NOT EXISTS (SELECT 1 FROM solid_queue_semaphore_log n WHERE n.key = s.key AND n.id > s.id)', v_table)
          USING v_part, i_now;
        GET DIAGNOSTICS v_copied = ROW_COUNT;
        EXECUTE format('TRUNCATE %I', v_table);
        RETURN v_copied;
      END $$;
    SQL
  end

  def down
    execute <<~SQL
      DROP FUNCTION solid_queue_semaphore_log_rotate(timestamp);
      DROP FUNCTION solid_queue_semaphore_signal(varchar, bigint, integer, timestamp, timestamp, boolean);
      DROP FUNCTION solid_queue_semaphore_held(varchar, bigint, timestamp);
      DROP FUNCTION solid_queue_semaphore_wait_all(json, timestamp);
      DROP FUNCTION solid_queue_semaphore_wait(varchar, integer, timestamp, timestamp);
      DROP FUNCTION solid_queue_semaphore_log_append(varchar, bigint, integer, timestamp, timestamp);
      DROP FUNCTION solid_queue_semaphore_log_current(varchar, timestamp);
      DROP FUNCTION solid_queue_semaphore_log_lock(varchar);
      DROP FUNCTION solid_queue_semaphore_log_part();
      DROP TABLE solid_queue_semaphore_log;
      DROP SEQUENCE solid_queue_semaphore_log_id_seq;
    SQL
  end
end
