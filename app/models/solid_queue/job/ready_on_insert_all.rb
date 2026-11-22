# frozen_string_literal: true

module SolidQueue
  class Job
    # On PostgreSQL, the due jobs with concurrency limits in a perform_all_later
    # take their slots for the whole set in two statements, before the jobs are
    # inserted, instead of one at a time after. The first creates the
    # semaphores that don't exist yet, with the slots taken from them already
    # counted, and locks the ones that do. The second takes slots from those,
    # as many as each has left. Each job that got a slot is inserted with it
    # recorded in its arguments, so it isn't updated afterwards, and is then
    # made ready with the others; the rest are inserted blocked.
    #
    # The jobs on a semaphore get its slots in the order they were given, as
    # dispatching them one at a time would. Locks are taken in the order the
    # other enqueues take them: the set's batches first, then the semaphores
    # by key, so sets and single jobs enqueued at the same time don't
    # deadlock. A set with a job that discards on conflict, with jobs on one
    # key with different limits or durations, with a limit below 1, or with
    # the same job twice, is dispatched one at a time.
    #
    # It needs Active Record 8 or later.
    module ReadyOnInsertAll
      SLOTS = :solid_queue_slots_taken

      # A perform_all_later inside another (from a callback) keeps its slots
      # apart from the outer one's.
      def enqueue_all(active_jobs)
        outer = ActiveSupport::IsolatedExecutionState[SLOTS]
        ActiveSupport::IsolatedExecutionState[SLOTS] = nil
        super
      ensure
        ActiveSupport::IsolatedExecutionState[SLOTS] = outer
      end

      def dispatch_all(jobs)
        slots = ActiveSupport::IsolatedExecutionState[SLOTS]
        taken, others = jobs.partition { |job| slots&.key?(job.active_job_id) }
        return super if taken.empty?

        ready, blocked = taken.partition { |job| slots[job.active_job_id] }
        ReadyExecution.create_all_from_jobs(ready) if ready.any?
        BlockedExecution.insert_all(blocked.map { |job| BlockedExecution.attributes_from_job(job).merge(job_id: job.id, expires_at: job.concurrency_duration.from_now) }) if blocked.any?

        (others.any? ? super(others) : []) + taken
      end

      private
        # The jobs are serialized before any slot is taken, so a job that can't
        # be fails the set before it takes one.
        def create_all_from_active_jobs(active_jobs)
          return super unless active_jobs.any?(&:concurrency_limited?)

          job_rows = active_jobs.map { |active_job| attributes_from_active_job(active_job) }
          if slots = with_connection { |connection| take_all_slots(connection, active_jobs, job_rows) }
            job_rows.each do |attributes|
              if lock = slots[attributes[:active_job_id]]
                attributes[:arguments] = attributes[:arguments].merge(ConcurrencyControls::CONCURRENCY_LOCK_KEY => lock)
              end
            end
            ActiveSupport::IsolatedExecutionState[SLOTS] = slots
          end

          insert_all(job_rows)
          where(active_job_id: active_jobs.map(&:job_id)).order(id: :asc)
        end

        # The slot each due limited job got, by its Active Job id: what's
        # recorded in its arguments, or nil if it got none. Nil when the set
        # isn't taking its slots this way. Keys are the ones the jobs are
        # stored with.
        def take_all_slots(connection, active_jobs, job_rows)
          now = Time.current
          limited = active_jobs.zip(job_rows).select { |job, _| job.concurrency_limited? && job.scheduled_at <= now }
          return if limited.empty? || !slots_takeable_for_all?(connection, active_jobs, limited)

          by_key = limited.group_by { |_, attributes| attributes[:concurrency_key] }.sort.to_h.transform_values { |pairs| pairs.map(&:first) }
          limits = by_key.transform_values { |jobs| jobs.first.class.concurrency_limit }
          expiries = by_key.transform_values { |jobs| connection.quoted_date(jobs.first.class.concurrency_duration.from_now) }

          lock_batches(connection, active_jobs)
          created = create_semaphores(connection, by_key.map { |key, jobs| { key:, value: limits[key] - [ jobs.size, limits[key] ].min, expires_at: expiries[key] } }, now)
          existing = by_key.keys - created.keys
          from_existing = existing.any? ? take_from_semaphores(connection, existing.map { |key| { key:, n: by_key[key].size, expires_at: expiries[key] } }) : {}

          by_key.each_with_object({}) do |(key, jobs), slots|
            semaphore_id, count = created.key?(key) ? [ created[key], [ jobs.size, limits[key] ].min ] : from_existing.fetch(key, [ nil, 0 ])
            jobs.each_with_index do |job, index|
              slots[job.job_id] = ({ "semaphore_id" => semaphore_id, "limit" => limits[key] } if index < count)
            end
          end
        end

        def slots_takeable_for_all?(connection, active_jobs, limited)
          defined?(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter) && connection.is_a?(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter) &&
            active_jobs.map(&:job_id).uniq.size == active_jobs.size &&
            limited.all? { |job, _| job.class.concurrency_on_conflict == :block && job.class.concurrency_limit.to_i >= 1 } &&
            limited.group_by { |_, attributes| attributes[:concurrency_key] }.values.all? { |pairs| pairs.map { |job, _| [ job.class.concurrency_limit, job.class.concurrency_duration ] }.uniq.one? }
        end

        # Single enqueues and stock dispatch count a job into its batch before
        # taking its slot, so the set locks its batches first too.
        def lock_batches(connection, active_jobs)
          batch_ids = Batch.migrated? ? active_jobs.filter_map(&:batch_id).uniq.sort : []
          return if batch_ids.empty?

          connection.exec_query(<<~SQL.squish, "#{Batch.name} Lock All", [ json_bind(batch_ids) ])
            SELECT id FROM #{Batch.quoted_table_name}
            WHERE id IN (SELECT value::bigint FROM json_array_elements_text($1::json)) ORDER BY id FOR NO KEY UPDATE
          SQL
        end

        # Inserts the semaphores that don't exist yet, and locks the ones that
        # do: the update's condition is never met, but the row is still locked.
        # Returns the ids of those inserted, by key.
        def create_semaphores(connection, rows, now)
          connection.exec_query(<<~SQL.squish, "#{Semaphore.name} Create All", [ json_bind(rows), time_bind(now) ]).rows.to_h { |id, key| [ key, id ] }
            INSERT INTO #{Semaphore.quoted_table_name} (key, value, expires_at, created_at, updated_at)
            SELECT key, value, expires_at, $2, $2 FROM json_to_recordset($1::json) AS wanted(key text, value integer, expires_at timestamp)
            ON CONFLICT (key) DO UPDATE SET value = #{Semaphore.quoted_table_name}.value WHERE false
            RETURNING id, key
          SQL
        end

        # Takes up to n slots from each existing, and now locked, semaphore.
        # Returns its id and how many it gave, by key.
        def take_from_semaphores(connection, rows)
          connection.exec_query(<<~SQL.squish, "#{Semaphore.name} Take All", [ json_bind(rows) ]).rows.to_h { |id, key, count| [ key, [ id, count ] ] }
            WITH wanted AS (
              SELECT * FROM json_to_recordset($1::json) AS wanted(key text, n integer, expires_at timestamp)
            ), taken AS (
              SELECT semaphores.id, semaphores.key, LEAST(wanted.n, GREATEST(semaphores.value, 0)) AS count, wanted.expires_at
              FROM #{Semaphore.quoted_table_name} semaphores JOIN wanted ON wanted.key = semaphores.key
            ), updated AS (
              UPDATE #{Semaphore.quoted_table_name} SET value = #{Semaphore.quoted_table_name}.value - taken.count, expires_at = taken.expires_at
              FROM taken WHERE #{Semaphore.quoted_table_name}.id = taken.id AND taken.count > 0
            )
            SELECT id, key, count FROM taken
          SQL
        end

        def json_bind(rows)
          ActiveRecord::Relation::QueryAttribute.new("rows", rows.to_json, ActiveRecord::Type::String.new)
        end

        def time_bind(time)
          ActiveRecord::Relation::QueryAttribute.new("now", time, Semaphore.type_for_attribute(:created_at))
        end
    end
  end
end
