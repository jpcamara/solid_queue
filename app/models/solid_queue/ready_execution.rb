# frozen_string_literal: true

module SolidQueue
  class ReadyExecution < Execution
    scope :queued_as, ->(queue_name) { where(queue_name: queue_name) }

    assumes_attributes_from_job

    class << self
      def claim(queue_list, limit, process_id)
        QueueSelector.new(queue_list, self).scoped_relations.flat_map do |queue_relation|
          select_and_lock(queue_relation, process_id, limit).tap do |locked|
            limit -= locked.size
          end
        end
      end

      def aggregated_count_across(queue_list)
        QueueSelector.new(queue_list, self).scoped_relations.map(&:count).sum
      end

      private
        def select_and_lock(queue_relation, process_id, limit)
          return [] if limit <= 0

          retrying_deadlocks do
            transaction do
              candidates = select_candidates(queue_relation, limit)
              lock_candidates(candidates, process_id)
            end
          end
        end

        # A claim that loses a deadlock, as claims on MySQL can to enqueues or other claims, has
        # been rolled back whole, so it's made again, a few times at most. Not within a transaction
        # someone else opened, though, as the deadlock rolled that back too.
        def retrying_deadlocks(attempts: 3)
          yield
        rescue ActiveRecord::Deadlocked
          raise if (attempts -= 1) < 0 || connection_pool.with_connection(&:transaction_open?)
          retry
        end

        def select_candidates(queue_relation, limit)
          # Force query execution here with #to_a to avoid unintended FOR UPDATE query executions
          queue_relation.ordered.limit(limit).non_blocking_lock.select(:id, :job_id).to_a
        end

        def lock_candidates(executions, process_id)
          return [] if executions.none?

          SolidQueue::ClaimedExecution.claiming(executions.map(&:job_id), process_id) do |claimed|
            ids_to_delete = executions.index_by(&:job_id).values_at(*claimed.map(&:job_id)).map(&:id)
            delete_by_primary_key(ids_to_delete)
          end
        end

        # MySQL can plan `DELETE ... WHERE id IN (...)` as a scan of the whole table when the list
        # covers much of it, as when a claim takes most of a short queue. Under REPEATABLE READ that
        # scan locks every row and the gap after the last one, so it waits on the rows that enqueues
        # are inserting, while the claim's SELECT ... FOR UPDATE SKIP LOCKED, having reached the end
        # of the queue, holds the gap those enqueues insert into: they deadlock. With the primary key
        # forced, the claim locks only the rows it deletes, which it has locked already. The hint is
        # a comment to PostgreSQL and SQLite, as with use_index (Arel doesn't add hints to deletes).
        def delete_by_primary_key(ids)
          connection_pool.with_connection do |connection|
            connection.delete sanitize_sql_array([ <<~SQL.squish, ids ]), "#{name} Delete All"
              DELETE /*+ INDEX(#{quoted_table_name} PRIMARY) */ FROM #{quoted_table_name}
              WHERE #{connection.quote_column_name(primary_key)} IN (?)
            SQL
          end
        end


        def discard_jobs(job_ids)
          Job.unblock_next_blocked_jobs Job.where(id: job_ids)
          super
        end
    end
  end
end
