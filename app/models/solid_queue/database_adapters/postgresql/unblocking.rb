# frozen_string_literal: true

module SolidQueue
  module DatabaseAdapters
    class Postgresql
      module Unblocking
        # A job that gives its concurrency slot back hands it to the next job
        # blocked on its key in one statement: it locks the next blocked
        # execution, as Base does, and leaves the slot taken in the semaphore
        # for it, records it in that job's arguments, makes the job ready and
        # deletes the blocked execution. With no job blocked, it gives the slot
        # back to the semaphore. That's instead of updating the semaphore,
        # locking the blocked execution, loading its job and releasing it, in a
        # transaction. A statement can change a row only once, so the semaphore
        # isn't given the slot and taken it from again.
        #
        # It locks the semaphore before the blocked execution, as giving the
        # slot back first does, so it waits for the semaphore with nothing else
        # locked.
        #
        # The slot is handed over when the semaphore is the one of the job's
        # concurrency key and isn't below zero, as a limit of zero leaves it,
        # so the slot given back would be there to take. It's handed to a job
        # of the same class and concurrency key, which has the same limit and
        # duration, whose arguments the statement can add the slot to.
        # Otherwise the slot goes back to the semaphore and the next blocked
        # job is released as in Base.
        #
        # It's for jobs that recorded the semaphore they got their slot from,
        # whose class loads, on a connection that allows writes, when blocked
        # executions locked by others are skipped. Others give their slot back
        # as in Base.
        def unblock_next(job)
          return super unless job.acquired_semaphore_id.present? && job.job_class.present? && SolidQueue.use_skip_locked && unblockable_on_connection?

          signalled, successor_id = unblock_in_one_statement(job)

          if successor_id
            SolidQueue.instrument(:release_blocked, job_id: successor_id, concurrency_key: job.concurrency_key, released: true)
            true
          elsif signalled
            # A job the statement couldn't hand the slot to, or one blocked
            # while the statement waited for the semaphore, which it couldn't see
            job.release_next_blocked_job
          end
        end

        private
          def unblockable_on_connection?
            Job.with_connection { |connection| !connection.preventing_writes? }
          end

          # Returns the id of the semaphore, or nil if the slot couldn't be
          # given back, as when the semaphore has expired, and the id of the
          # job handed the slot, or nil if none was.
          def unblock_in_one_statement(job)
            Job.with_connection do |connection|
              binds = []
              bind = ->(value, model, attribute) do
                binds << ActiveRecord::Relation::QueryAttribute.new(attribute.to_s, value, model.type_for_attribute(attribute))
                "CAST($#{binds.size} AS #{model.columns_hash[attribute.to_s].sql_type})"
              end
              jobs, blocked = Job.quoted_table_name, BlockedExecution.quoted_table_name
              key, now = bind.(job.concurrency_key, Job, :concurrency_key), bind.(Time.current, ReadyExecution, :created_at)
              lock_key = Job::ConcurrencyControls::CONCURRENCY_LOCK_KEY
              semaphore_id = bind.(job.acquired_semaphore_id, Semaphore, :id)
              lock = "',#{connection.quote_string(lock_key.to_json)}:{\"semaphore_id\":' || semaphore.id || ',\"limit\":' || #{bind.(job.concurrency_limit, Semaphore, :value)} || '}}'"
              limit = bind.(job.acquired_concurrency_limit || job.concurrency_limit, Semaphore, :value)
              expires_at = bind.(job.concurrency_duration.from_now, Semaphore, :expires_at)

              # As the statements it replaces would
              ActiveRecord::Base.clear_query_caches_for_current_thread if connection.pool.dirties_query_cache

              # Prepared, which Active Record only does for a string when told it can
              with_slots_locked(connection, [ job.concurrency_key ]) { connection.select_all(<<~SQL.squish, "#{Job.name} Unblock", binds, preparable: true).rows.first }
                WITH held AS (
                  #{hold_semaphore_sql(semaphore_id:, key:, now:)}
                ), next AS (
                  SELECT id, job_id FROM #{blocked} WHERE concurrency_key = #{key} AND EXISTS (SELECT 1 FROM held)
                  ORDER BY priority ASC, job_id ASC LIMIT 1 FOR UPDATE SKIP LOCKED
                ), successor AS (
                  SELECT next.id, #{jobs}.id AS job_id, #{jobs}.queue_name, #{jobs}.priority
                  FROM next JOIN #{jobs} ON #{jobs}.id = next.job_id
                  WHERE #{jobs}.class_name = #{bind.(job.class_name, Job, :class_name)} AND #{jobs}.concurrency_key = #{key}
                    AND right(#{jobs}.arguments, 1) = '}'
                    AND right(rtrim(left(#{jobs}.arguments, -1), E' \\t\\n\\r'), 1) <> '{'
                    AND position('#{connection.quote_string(lock_key)}' in #{jobs}.arguments) = 0
                ), semaphore AS (
                  #{give_back_slot_sql(semaphore_id:, key:, limit:, expires_at:, now:, handed_over: "EXISTS (SELECT 1 FROM successor)")}
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
end
