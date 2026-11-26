# frozen_string_literal: true

module SolidQueue
  module DatabaseAdapters
    class Postgresql
      module BulkEnqueuing
        # The due jobs with concurrency limits in a perform_all_later take
        # their slots for the whole set in two statements, before the jobs are
        # inserted, instead of one at a time after. The first creates the
        # semaphores that don't exist yet, with the slots taken from them
        # already counted, and locks the ones that do. The second takes slots
        # from those, as many as each has left. Each job that got a slot is
        # inserted with it recorded in its arguments, so it isn't updated
        # afterwards, and is then made ready with the others; the rest are
        # inserted blocked.
        #
        # The jobs on a semaphore get its slots in the order they were given,
        # as dispatching them one at a time would. Locks are taken in the order
        # the other enqueues take them: the set's batches first, then the
        # semaphores by key, so sets and single jobs enqueued at the same time
        # don't deadlock. A set with a job that discards on conflict, with jobs
        # on one key with different limits or durations, with a limit below 1,
        # or with the same job twice, is dispatched one at a time, and a set
        # without limited jobs is enqueued as in Base.
        def enqueue_all(active_jobs)
          return super unless active_jobs.any?(&:concurrency_limited?)

          # The jobs are serialized before any slot is taken, so a job that
          # can't be fails the set before it takes one.
          job_rows = active_jobs.map { |active_job| Job.attributes_from_active_job(active_job) }
          if slots = Job.with_connection { |connection| take_all_slots(connection, active_jobs, job_rows) }
            job_rows.each do |attributes|
              if lock = slots[attributes[:active_job_id]]
                attributes[:arguments] = attributes[:arguments].merge(Job::ConcurrencyControls::CONCURRENCY_LOCK_KEY => lock)
              end
            end
          end

          jobs = Job.create_all_from_rows(job_rows)
          return Job.prepare_all_for_execution(jobs) unless slots

          # As Job.prepare_all_for_execution, dispatching those given a slot,
          # or none, without taking one again
          Job.batch_all(jobs)
          due, not_yet_due = jobs.partition(&:due?)
          dispatch_all_with_slots(due, slots) + Job.schedule_all(not_yet_due)
        end

        private
          def dispatch_all_with_slots(jobs, slots)
            taken, others = jobs.partition { |job| slots.key?(job.active_job_id) }
            return Job.dispatch_all(jobs) if taken.empty?

            ready, blocked = taken.partition { |job| slots[job.active_job_id] }
            ReadyExecution.create_all_from_jobs(ready) if ready.any?
            BlockedExecution.insert_all(blocked.map { |job| BlockedExecution.attributes_from_job(job).merge(job_id: job.id, expires_at: job.concurrency_duration.from_now) }) if blocked.any?

            (others.any? ? Job.dispatch_all(others) : []) + taken
          end

          # The slot each due limited job got, by its Active Job id: what's
          # recorded in its arguments, or nil if it got none. Nil when the set
          # isn't taking its slots this way. Keys are the ones the jobs are
          # stored with.
          def take_all_slots(connection, active_jobs, job_rows)
            now = Time.current
            limited = active_jobs.zip(job_rows).select { |job, _| job.concurrency_limited? && job.scheduled_at <= now }
            return if limited.empty? || !slots_takeable_for_all?(active_jobs, limited)

            by_key = limited.group_by { |_, attributes| attributes[:concurrency_key] }.sort.to_h.transform_values { |pairs| pairs.map(&:first) }
            limits = by_key.transform_values { |jobs| jobs.first.class.concurrency_limit }
            expiries = by_key.transform_values { |jobs| connection.quoted_date(jobs.first.class.concurrency_duration.from_now) }

            lock_batches(connection, active_jobs)
            taken = take_slots_for_all(connection, by_key.map { |key, jobs| { key:, n: jobs.size, limit: limits[key], expires_at: expiries[key] } }, now)

            by_key.each_with_object({}) do |(key, jobs), slots|
              semaphore_id, count = taken[key]
              jobs.each_with_index do |job, index|
                slots[job.job_id] = ({ "semaphore_id" => semaphore_id, "limit" => limits[key] } if index < count)
              end
            end
          end

          def slots_takeable_for_all?(active_jobs, limited)
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

          def json_bind(rows)
            ActiveRecord::Relation::QueryAttribute.new("rows", rows.to_json, ActiveRecord::Type::String.new)
          end

          def time_bind(time)
            ActiveRecord::Relation::QueryAttribute.new("now", time, Semaphore.type_for_attribute(:created_at))
          end
      end
    end
  end
end
