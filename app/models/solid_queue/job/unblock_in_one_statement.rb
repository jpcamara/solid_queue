# frozen_string_literal: true

module SolidQueue
  class Job
    # On PostgreSQL, a job that gives its concurrency slot back hands it to
    # the next job blocked on its key in one statement: it locks the next
    # blocked execution, as before, and leaves the slot taken in the
    # semaphore for it, records it in that job's arguments, makes the job
    # ready and deletes the blocked execution. With no job blocked, it gives
    # the slot back to the semaphore. That's instead of updating the
    # semaphore, locking the blocked execution, loading its job and releasing
    # it, in a transaction. A statement can change a row only once, so the
    # semaphore isn't given the slot and taken it from again.
    #
    # It locks the semaphore before the blocked execution, as giving the slot
    # back first did, so it waits for the semaphore with nothing else locked.
    #
    # The slot is handed over when the semaphore is the one of the job's
    # concurrency key and isn't below zero, as a limit of zero leaves it, so
    # the slot given back would be there to take. It's handed to a job of the
    # same class and concurrency key, which has the same limit and duration,
    # whose arguments the statement can add the slot to. Otherwise the slot
    # goes back to the semaphore and the next blocked job is released as
    # before.
    #
    # It's for jobs that recorded the semaphore they got their slot from,
    # whose class loads, on a connection that allows writes, when blocked
    # executions locked by others are skipped. Others give their slot back
    # as before.
    #
    # It needs Active Record 8 or later.
    module UnblockInOneStatement
      def unblock_next_blocked_job
        return super unless acquired_semaphore_id.present? && job_class.present? && SolidQueue.use_skip_locked && unblockable_on_connection?

        signalled, successor_id = unblock_statement

        if successor_id
          SolidQueue.instrument(:release_blocked, job_id: successor_id, concurrency_key: concurrency_key, released: true)
          true
        elsif signalled
          # A job the statement couldn't hand the slot to, or one blocked
          # while the statement waited for the semaphore, which it couldn't see
          release_next_blocked_job
        end
      end

      private
        def unblockable_on_connection?
          self.class.with_connection do |connection|
            defined?(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter) && connection.is_a?(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter) &&
              !connection.preventing_writes?
          end
        end

        # Returns the id of the semaphore, or nil if the slot couldn't be
        # given back, as when the semaphore has expired, and the id of the
        # job handed the slot, or nil if none was.
        def unblock_statement
          self.class.with_connection do |connection|
            binds = []
            bind = ->(value, model, attribute) do
              binds << ActiveRecord::Relation::QueryAttribute.new(attribute.to_s, value, model.type_for_attribute(attribute))
              "CAST($#{binds.size} AS #{model.columns_hash[attribute.to_s].sql_type})"
            end
            jobs, semaphores, blocked = self.class.quoted_table_name, Semaphore.quoted_table_name, BlockedExecution.quoted_table_name
            key, now = bind.(concurrency_key, self.class, :concurrency_key), bind.(Time.current, ReadyExecution, :created_at)
            lock_key = ConcurrencyControls::CONCURRENCY_LOCK_KEY
            semaphore_id = bind.(acquired_semaphore_id, Semaphore, :id)
            lock = "',#{connection.quote_string(lock_key.to_json)}:{\"semaphore_id\":' || semaphore.id || ',\"limit\":' || #{bind.(concurrency_limit, Semaphore, :value)} || '}}'"

            # As the statements it replaces would
            ActiveRecord::Base.clear_query_caches_for_current_thread if connection.pool.dirties_query_cache

            # Prepared, which Active Record only does for a string when told it can
            connection.select_all(<<~SQL.squish, "#{self.class.name} Unblock", binds, preparable: true).rows.first
              WITH held AS (
                SELECT id FROM #{semaphores} WHERE id = #{semaphore_id} AND key = #{key} AND value >= 0 FOR UPDATE
              ), next AS (
                SELECT id, job_id FROM #{blocked} WHERE concurrency_key = #{key} AND EXISTS (SELECT 1 FROM held)
                ORDER BY priority ASC, job_id ASC LIMIT 1 FOR UPDATE SKIP LOCKED
              ), successor AS (
                SELECT next.id, #{jobs}.id AS job_id, #{jobs}.queue_name, #{jobs}.priority
                FROM next JOIN #{jobs} ON #{jobs}.id = next.job_id
                WHERE #{jobs}.class_name = #{bind.(class_name, self.class, :class_name)} AND #{jobs}.concurrency_key = #{key}
                  AND right(#{jobs}.arguments, 1) = '}'
                  AND right(rtrim(left(#{jobs}.arguments, -1), E' \\t\\n\\r'), 1) <> '{'
                  AND position('#{connection.quote_string(lock_key)}' in #{jobs}.arguments) = 0
              ), semaphore AS (
                UPDATE #{semaphores} SET value = value + CASE WHEN EXISTS (SELECT 1 FROM successor) THEN 0 ELSE 1 END,
                  expires_at = #{bind.(concurrency_duration.from_now, Semaphore, :expires_at)}
                WHERE id = #{semaphore_id} AND value < #{bind.(acquired_concurrency_limit || concurrency_limit, Semaphore, :value)}
                RETURNING id
              ), job AS (
                UPDATE #{jobs} SET arguments = left(arguments, -1) || #{lock}
                FROM semaphore, successor WHERE #{jobs}.id = successor.job_id
              ), ready AS (
                INSERT INTO #{ReadyExecution.quoted_table_name} (job_id, queue_name, priority, created_at)
                SELECT successor.job_id, successor.queue_name, successor.priority, #{now} FROM successor, semaphore
              ), released AS (
                DELETE FROM #{blocked} USING successor, semaphore WHERE #{blocked}.id = successor.id
              )
              SELECT semaphore.id, successor.job_id FROM semaphore LEFT JOIN successor ON TRUE
            SQL
          end
        end
    end
  end
end
