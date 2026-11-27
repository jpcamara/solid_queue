# frozen_string_literal: true

module SolidQueue
  module DatabaseAdapters
    class Postgresql
      module Dispatching
        # Jobs with concurrency limits dispatched after their insert, like
        # scheduled jobs coming due and failed jobs retried, take their slots
        # for the whole set as a perform_all_later's do, in the order
        # dispatching them one at a time would, by key and then id. That's
        # instead of checking, taking and recording each job's slot, and
        # making it ready, blocking it or discarding it, in statements of its
        # own, while the keys of the jobs before it stay locked.
        #
        # Then one statement records the slots in the arguments of the jobs
        # that got one, as record_concurrency_lock does, one makes those jobs
        # ready, one blocks the jobs to be blocked, and one deletes those
        # discarded. A job discarded from a batch is destroyed instead, so
        # its batch checks whether it has finished.
        #
        # A set take_all_slots can't take slots for is dispatched one at a
        # time, as in Base.
        def dispatch_limited(jobs)
          return super unless slots_takeable_for_all?(jobs)

          Job.with_connection do |connection|
            connection.transaction do
              slots = take_all_slots(connection, jobs.sort_by(&:id), batches_of: [])

              record_slots(connection, jobs.select { |job| slots[job] }, slots)
              ReadyExecution.create_all_from_jobs(jobs.select { |job| slots[job] }) if jobs.any? { |job| slots[job] }
              block_all(jobs.select { |job| slots[job].nil? })
              discard_all(jobs.select { |job| slots[job] == false })
            end
          end
        end

        private
          def record_slots(connection, jobs, slots)
            return if jobs.empty?

            type = Job.type_for_attribute(:arguments)
            rows = jobs.map do |job|
              job.arguments[Job::ConcurrencyControls::CONCURRENCY_LOCK_KEY] = slots[job]
              { id: job.id, arguments: type.serialize(job.arguments) }
            end

            connection.exec_update(<<~SQL.squish, "#{Job.name} Update All", [ json_bind(rows) ])
              UPDATE #{Job.quoted_table_name} SET arguments = recorded.arguments
              FROM json_to_recordset($1::json) AS recorded(id bigint, arguments text)
              WHERE #{Job.quoted_table_name}.id = recorded.id
            SQL
          end

          def discard_all(jobs)
            batched, unbatched = jobs.partition(&:batched?)
            Job.where(id: unbatched.map(&:id)).delete_all if unbatched.any?
            batched.each(&:destroy)
          end
      end
    end
  end
end
