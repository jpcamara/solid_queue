# frozen_string_literal: true

module SolidQueue
  module DatabaseAdapters
    class Postgresql
      module Releasing
        # Releases in one statement: the job takes a slot as Semaphore.wait
        # does, and if it got one, the statement records it in the job's
        # arguments, makes the job ready and deletes the blocked execution.
        # That's instead of locking the semaphore, updating it, updating the
        # job, loading it again, inserting the ready execution and deleting the
        # blocked one. It runs in the transaction the release always used.
        #
        # It's for jobs whose class loads, with nothing to save, whose
        # arguments the statement can add the slot to, as on enqueue, on a
        # connection that allows writes. Others are released as in Base.
        def release(blocked_execution)
          return super unless releasable_in_one_statement?(blocked_execution)

          job = blocked_execution.job
          SolidQueue.instrument(:release_blocked, job_id: job.id, concurrency_key: blocked_execution.concurrency_key, released: false) do |payload|
            BlockedExecution.transaction do
              if semaphore_id = release_in_one_statement(blocked_execution)
                job.arguments[Job::ConcurrencyControls::CONCURRENCY_LOCK_KEY] = { "semaphore_id" => semaphore_id, "limit" => job.concurrency_limit }
                job.clear_attribute_changes([ "arguments" ])
                payload[:released] = true
              end
            end
          end
        end

        private
          def releasable_in_one_statement?(blocked_execution)
            job = blocked_execution.job

            !blocked_execution.readonly? && job.job_class.present? && !job.has_changes_to_save? && slot_addable_to_stored_arguments?(job) &&
              BlockedExecution.with_connection { |connection| !connection.preventing_writes? }
          end

          # The statement adds the slot's entry after the serialized arguments'
          # last key, where recording it would, so they need one, mustn't have
          # the entry already, and must end with the object's closing brace.
          def slot_addable_to_stored_arguments?(job)
            job.arguments.is_a?(Hash) && job.arguments.any? && !job.arguments.key?(Job::ConcurrencyControls::CONCURRENCY_LOCK_KEY) &&
              job.arguments_before_type_cast.to_s.end_with?("}")
          end

          # Returns the id of the semaphore the job got its slot from, or nil if
          # it got none and is left blocked.
          def release_in_one_statement(blocked_execution)
            BlockedExecution.with_connection do |connection|
              binds = []
              bind = ->(value, model, attribute) do
                binds << ActiveRecord::Relation::QueryAttribute.new(attribute.to_s, value, model.type_for_attribute(attribute))
                "CAST($#{binds.size} AS #{model.columns_hash[attribute.to_s].sql_type})"
              end
              job = blocked_execution.job
              limit, now = bind.(job.concurrency_limit, Semaphore, :value), bind.(Time.current, Semaphore, :created_at)
              expires_at, key = bind.(job.concurrency_duration.from_now, Semaphore, :expires_at), bind.(job.concurrency_key, Semaphore, :key)
              released_job, id = bind.(job.id, Job, :id), bind.(blocked_execution.id, BlockedExecution, :id)
              lock = "',#{connection.quote_string(Job::ConcurrencyControls::CONCURRENCY_LOCK_KEY.to_json)}:{\"semaphore_id\":' || semaphore.id || ',\"limit\":' || #{limit} || '}}'"

              # As the statements it replaces would
              ActiveRecord::Base.clear_query_caches_for_current_thread if connection.pool.dirties_query_cache

              # Prepared, which Active Record only does for a string when told it can
              connection.select_all(<<~SQL.squish, "#{BlockedExecution.name} Release", binds, preparable: true).rows.dig(0, 0)
                WITH semaphore AS (
                  #{take_slot_sql(key:, limit:, expires_at:, now:)}
                ), job AS (
                  UPDATE #{Job.quoted_table_name} SET arguments = left(arguments, -1) || #{lock}
                  FROM semaphore WHERE #{Job.quoted_table_name}.id = #{released_job}
                ), ready AS (
                  INSERT INTO #{ReadyExecution.quoted_table_name} (job_id, queue_name, priority, created_at)
                  SELECT #{released_job}, #{bind.(job.queue_name, ReadyExecution, :queue_name)}, #{bind.(job.priority, ReadyExecution, :priority)}, #{now} FROM semaphore
                ), released AS (
                  DELETE FROM #{BlockedExecution.quoted_table_name} USING semaphore WHERE #{BlockedExecution.quoted_table_name}.id = #{id}
                )
                SELECT id FROM semaphore
              SQL
            end
          end
      end
    end
  end
end
