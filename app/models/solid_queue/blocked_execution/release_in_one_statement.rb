# frozen_string_literal: true

module SolidQueue
  class BlockedExecution
    # On PostgreSQL, a blocked job is released in one statement: it takes a
    # slot as Semaphore.wait does, and if it got one, records it in the job's
    # arguments, makes the job ready and deletes the blocked execution. That's
    # instead of locking the semaphore, updating it, updating the job,
    # loading it again, inserting the ready execution and deleting the blocked
    # one. It runs in the transaction the release always used.
    #
    # It's for jobs whose class loads, with nothing to save, whose arguments
    # the statement can add the slot to, as on enqueue, on a connection that
    # allows writes. Others are released as before.
    #
    # It needs Active Record 8 or later.
    module ReleaseInOneStatement
      def release
        return super unless releasable_in_one_statement?

        SolidQueue.instrument(:release_blocked, job_id: job.id, concurrency_key: concurrency_key, released: false) do |payload|
          transaction do
            if semaphore_id = release_statement
              job.arguments[Job::ConcurrencyControls::CONCURRENCY_LOCK_KEY] = { "semaphore_id" => semaphore_id, "limit" => job.concurrency_limit }
              job.clear_attribute_changes([ "arguments" ])
              payload[:released] = true
            end
          end
        end
      end

      private
        def releasable_in_one_statement?
          !readonly? && job.job_class.present? && !job.has_changes_to_save? && slot_recordable_in_arguments? &&
            self.class.with_connection do |connection|
              defined?(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter) && connection.is_a?(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter) &&
                !connection.preventing_writes?
            end
        end

        # The statement adds the slot's entry after the serialized arguments'
        # last key, where recording it would, so they need one, mustn't have
        # the entry already, and must end with the object's closing brace.
        def slot_recordable_in_arguments?
          job.arguments.is_a?(Hash) && job.arguments.any? && !job.arguments.key?(Job::ConcurrencyControls::CONCURRENCY_LOCK_KEY) &&
            job.arguments_before_type_cast.to_s.end_with?("}")
        end

        # Returns the id of the semaphore the job got its slot from, or nil if
        # it got none and is left blocked.
        def release_statement
          self.class.with_connection do |connection|
            binds = []
            bind = ->(value, model, attribute) do
              binds << ActiveRecord::Relation::QueryAttribute.new(attribute.to_s, value, model.type_for_attribute(attribute))
              "CAST($#{binds.size} AS #{model.columns_hash[attribute.to_s].sql_type})"
            end
            semaphores = Semaphore.quoted_table_name
            limit, now = bind.(job.concurrency_limit, Semaphore, :value), bind.(Time.current, Semaphore, :created_at)
            expires_at, key = bind.(job.concurrency_duration.from_now, Semaphore, :expires_at), bind.(job.concurrency_key, Semaphore, :key)
            released_job, id = bind.(job.id, Job, :id), bind.(self.id, self.class, :id)
            lock = "',#{connection.quote_string(Job::ConcurrencyControls::CONCURRENCY_LOCK_KEY.to_json)}:{\"semaphore_id\":' || semaphore.id || ',\"limit\":' || #{limit} || '}}'"

            # As the statements it replaces would
            ActiveRecord::Base.clear_query_caches_for_current_thread if connection.pool.dirties_query_cache

            # Prepared, which Active Record only does for a string when told it can
            connection.select_all(<<~SQL.squish, "#{self.class.name} Release", binds, preparable: true).rows.dig(0, 0)
              WITH semaphore AS (
                INSERT INTO #{semaphores} (key, value, expires_at, created_at, updated_at)
                VALUES (#{key}, #{limit} - 1, #{expires_at}, #{now}, #{now})
                ON CONFLICT (key) DO UPDATE SET value = #{semaphores}.value - 1, expires_at = EXCLUDED.expires_at
                WHERE #{semaphores}.value > 0
                RETURNING id
              ), job AS (
                UPDATE #{Job.quoted_table_name} SET arguments = left(arguments, -1) || #{lock}
                FROM semaphore WHERE #{Job.quoted_table_name}.id = #{released_job}
              ), ready AS (
                INSERT INTO #{ReadyExecution.quoted_table_name} (job_id, queue_name, priority, created_at)
                SELECT #{released_job}, #{bind.(job.queue_name, ReadyExecution, :queue_name)}, #{bind.(job.priority, ReadyExecution, :priority)}, #{now} FROM semaphore
              ), released AS (
                DELETE FROM #{self.class.quoted_table_name} USING semaphore WHERE #{self.class.quoted_table_name}.id = #{id}
              )
              SELECT id FROM semaphore
            SQL
          end
        end
    end
  end
end
