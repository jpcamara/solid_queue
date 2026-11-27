# frozen_string_literal: true

module SolidQueue
  module DatabaseAdapters
    class Postgresql
      # Semaphores kept in solid_queue_semaphore_log, where taking or giving
      # back a slot inserts a row, instead of a row per key that every slot
      # taken and given back updates. A key's semaphore is its newest row,
      # until that row expires.
      #
      # An updated row leaves its old version behind until vacuum removes it,
      # and vacuum can't while any transaction older than it is open, on the
      # primary or, with hot_standby_feedback, on a replica. A busy key's index
      # entries then lead to thousands of dead versions, and every lookup walks
      # them. Here a key's newest row is the first index entry read, however
      # many rows came before it, deleted or not.
      #
      # Callers on a key take turns through an advisory lock on it, held until
      # their transaction ends, taken in a statement of its own: under READ
      # COMMITTED, each statement sees what was committed before it started, so
      # the statement after the lock sees what the last holder committed.
      module SemaphoreLog
        LOG = "solid_queue_semaphore_log"

        def take_slot(job)
          Semaphore.with_connection do |connection|
            with_slots_locked(connection, [ job.concurrency_key ]) do
              binds, bind = binder
              sql = take_slot_sql(key: bind.(job.concurrency_key, :key), limit: bind.(job.concurrency_limit, :value),
                expires_at: bind.(job.concurrency_duration.from_now, :expires_at), now: bind.(Time.current, :created_at))
              connection.exec_query(sql, "#{Semaphore.name} Wait", binds).rows.dig(0, 0)
            end
          end
        end

        def give_back_slot(job)
          Semaphore.with_connection do |connection|
            with_slots_locked(connection, [ job.concurrency_key ]) do
              binds, bind = binder
              sql = give_back_slot_sql(key: bind.(job.concurrency_key, :key), semaphore_id: bind.(job.acquired_semaphore_id, :id),
                limit: bind.(job.acquired_concurrency_limit || job.concurrency_limit, :value), expires_at: bind.(job.concurrency_duration.from_now, :expires_at),
                now: bind.(Time.current, :created_at), handed_over: "false")
              connection.exec_query(sql, "#{Semaphore.name} Signal", binds).rows.any?
            end
          end
        end

        def keys_with_free_slots(keys)
          return [] if keys.empty?

          Semaphore.with_connection do |connection|
            connection.select_values(<<~SQL.squish, "#{Semaphore.name} Free", [ json_bind(keys), time_bind(Time.current) ])
              SELECT keys.key FROM json_array_elements_text($1::json) AS keys(key)
              LEFT JOIN LATERAL (SELECT value, expires_at FROM #{LOG} WHERE key = keys.key ORDER BY id DESC LIMIT 1) newest ON true
              WHERE newest.value IS NULL OR newest.expires_at <= $2 OR newest.value > 0
            SQL
          end
        end

        def lock_concurrency_key(key)
          Semaphore.with_connection { |connection| with_slots_locked(connection, [ key ]) { } }
        end

        def full_with_blocked?(key, count)
          Semaphore.with_connection do |connection|
            binds, bind = binder
            key, offset = bind.(key, :key), bind.(count - 1, :value)
            connection.select_value(<<~SQL.squish, "#{Semaphore.name} Full", binds).present?
              SELECT 1 FROM #{current_semaphore_sql(key, bind.(Time.current, :created_at))} current
              WHERE current.value <= 0 AND (#{offset} < 0 OR EXISTS (
                SELECT 1 FROM #{BlockedExecution.quoted_table_name} WHERE concurrency_key = #{key} LIMIT 1 OFFSET GREATEST(#{offset}, 0)
              ))
            SQL
          end
        end

        # Deletes the rows no lookup reads any more: those a newer row of their
        # key replaced, and those that have expired. Each batch starts after
        # the last one; the first still reads through what earlier runs deleted
        # until vacuum removes it.
        def expire_semaphores(batch_size)
          Semaphore.with_connection do |connection|
            from, now = 0, Time.current
            loop do
              deleted = connection.exec_query(<<~SQL.squish, "#{Semaphore.name} Clear", [ id_bind(from), time_bind(now), id_bind(batch_size) ]).rows.flatten
                DELETE FROM #{LOG} WHERE id IN (
                  SELECT id FROM #{LOG} old WHERE id > $1
                    AND (expires_at <= $2 OR EXISTS (SELECT 1 FROM #{LOG} newer WHERE newer.key = old.key AND newer.id > old.id))
                  ORDER BY id LIMIT $3
                )
                RETURNING id
              SQL
              break if deleted.size < batch_size

              from = deleted.max
            end
          end
        end

        private
          # Runs the block with the keys' advisory locks taken, in byte order, in
          # a transaction, which the locks are held until the end of. The
          # batches of the jobs given are locked first, as other enqueues count
          # a job into its batch before taking its slot.
          def with_slots_locked(connection, keys, batches_of: [])
            return yield if keys.empty?

            connection.transaction do
              lock_batches(connection, batches_of)
              # The locks are taken in a subquery, so their void results aren't returned
              isolation = connection.select_values(<<~SQL.squish, "#{Semaphore.name} Lock", [ json_bind(keys.uniq) ]).first
                SELECT current_setting('transaction_isolation') FROM (
                  SELECT pg_advisory_xact_lock(hashtextextended('#{LOG}/' || key, 0))
                  FROM json_array_elements_text($1::json) AS keys(key) ORDER BY key COLLATE "C"
                ) locks
              SQL
              unless isolation == "read committed"
                raise ActiveRecord::TransactionIsolationError, "Solid Queue's semaphore log needs READ COMMITTED, not #{isolation.upcase}"
              end

              yield
            end
          end

          # with_slots_locked locks the key, after the job's batch, in a statement
          # of its own already.
          def lock_semaphore_first(connection, job)
          end

          # The key's semaphore: its newest row, unless it has expired
          def current_semaphore_sql(key, now)
            "(SELECT * FROM (SELECT semaphore_id, value, expires_at FROM #{LOG} WHERE key = #{key} ORDER BY id DESC LIMIT 1) newest WHERE expires_at > #{now})"
          end

          # Creating the semaphore always takes a slot, even with a limit of 0,
          # as in Semaphore.wait. A new semaphore's id is its first row's.
          def take_slot_sql(key:, limit:, expires_at:, now:, condition: nil)
            <<~SQL
              INSERT INTO #{LOG} (id, key, semaphore_id, value, expires_at, created_at)
              SELECT fresh.id, #{key}, COALESCE(current.semaphore_id, fresh.id), COALESCE(current.value, #{limit}) - 1, #{expires_at}, #{now}
              FROM (SELECT nextval('#{LOG}_id_seq') AS id) fresh LEFT JOIN #{current_semaphore_sql(key, now)} current ON true
              WHERE (current.semaphore_id IS NULL OR current.value > 0) #{"AND #{condition}" if condition}
              RETURNING semaphore_id AS id
            SQL
          end

          # A null semaphore_id, for jobs that didn't record theirs, matches any
          def hold_semaphore_sql(semaphore_id:, key:, now:)
            "SELECT semaphore_id AS id FROM #{current_semaphore_sql(key, now)} current WHERE (#{semaphore_id} IS NULL OR semaphore_id = #{semaphore_id}) AND value >= 0"
          end

          def give_back_slot_sql(semaphore_id:, key:, limit:, expires_at:, now:, handed_over:)
            <<~SQL
              INSERT INTO #{LOG} (key, semaphore_id, value, expires_at, created_at)
              SELECT #{key}, semaphore_id, value + CASE WHEN #{handed_over} THEN 0 ELSE 1 END, #{expires_at}, #{now}
              FROM #{current_semaphore_sql(key, now)} current
              WHERE (#{semaphore_id} IS NULL OR semaphore_id = #{semaphore_id}) AND value < #{limit}
              RETURNING semaphore_id AS id
            SQL
          end

          def take_slots_for_all(connection, wanted, now)
            with_slots_locked(connection, wanted.map { |w| w[:key] }) do
              connection.exec_query(<<~SQL.squish, "#{Semaphore.name} Wait All", [ json_bind(wanted), time_bind(now) ]).rows.to_h { |key, semaphore_id, taken| [ key, [ semaphore_id, taken ] ] }
                WITH wanted AS (
                  SELECT * FROM json_to_recordset($1::json) AS wanted(key varchar, n integer, "limit" integer, expires_at timestamp)
                ), taking AS (
                  SELECT wanted.*, nextval('#{LOG}_id_seq') AS id, current.semaphore_id, current.value,
                    CASE WHEN current.semaphore_id IS NULL THEN LEAST(wanted.n, wanted."limit") ELSE LEAST(wanted.n, GREATEST(current.value, 0)) END AS taken
                  FROM wanted LEFT JOIN LATERAL #{current_semaphore_sql("wanted.key", "$2")} current ON true
                ), inserted AS (
                  INSERT INTO #{LOG} (id, key, semaphore_id, value, expires_at, created_at)
                  SELECT id, key, COALESCE(semaphore_id, id), COALESCE(value, "limit") - taken, expires_at, $2
                  FROM taking WHERE semaphore_id IS NULL OR taken > 0
                )
                SELECT key, COALESCE(semaphore_id, id), taken FROM taking
              SQL
            end
          end

          def binder
            binds = []
            bind = ->(value, attribute) do
              binds << ActiveRecord::Relation::QueryAttribute.new(attribute.to_s, value, Semaphore.type_for_attribute(attribute))
              "CAST($#{binds.size} AS #{Semaphore.columns_hash[attribute.to_s].sql_type})"
            end
            [ binds, bind ]
          end

          def id_bind(id)
            ActiveRecord::Relation::QueryAttribute.new("id", id, ActiveRecord::Type::Integer.new(limit: 8))
          end
      end
    end
  end
end
