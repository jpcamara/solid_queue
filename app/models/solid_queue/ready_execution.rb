# frozen_string_literal: true

module SolidQueue
  class ReadyExecution < Execution
    scope :queued_as, ->(queue_name) { where(queue_name: queue_name) }

    # Within a priority, claims follow the order rows became ready (id) rather
    # than enqueue order (job_id), matching the claim cursor's index position.
    scope :ordered, -> { order(priority: :asc, id: :asc) }

    assumes_attributes_from_job

    class << self
      def claim(queue_list, limit, process_id)
        QueueSelector.new(queue_list, self).relations_by_queue.flat_map do |key, queue_relation|
          select_and_lock(key, queue_relation, process_id, limit).tap do |locked|
            limit -= locked.size
          end
        end
      end

      def aggregated_count_across(queue_list)
        QueueSelector.new(queue_list, self).scoped_relations.map(&:count).sum
      end

      def claim_cursors
        @claim_cursors ||= ClaimCursors.new
      end

      private
        def select_and_lock(key, queue_relation, process_id, limit)
          return [] if limit <= 0

          unless claim_cursors_enabled?
            return claim_classically(queue_relation, process_id, limit)
          end

          discovery_due, position = claim_cursors.state(key)

          if discovery_due
            claim_discovering(key, queue_relation, process_id, limit)
          elsif position
            claim_along_cursor(key, position, queue_relation, process_id, limit)
          else
            []
          end
        end

        def claim_classically(queue_relation, process_id, limit)
          _candidates, claimed = claim_candidates(queue_relation, process_id, limit)
          claimed
        end

        # Cursor-free claim in full (priority, id) order. Discovery both seeds
        # the fast path and finds rows that appeared below its position.
        def claim_discovering(key, queue_relation, process_id, limit)
          candidates, claimed = claim_candidates(queue_relation, process_id, limit)
          claim_cursors.record_discovery(key, position_of(candidates.last))
          claimed
        end

        # One lexicographic index seek across every priority in the queue key.
        def claim_along_cursor(key, position, queue_relation, process_id, limit)
          candidates, claimed = claim_candidates(
            queue_relation.where("(priority, id) > (?, ?)", *position), process_id, limit
          )

          if candidates.any?
            claim_cursors.advance(key, position_of(candidates.last))
          else
            # Under SKIP LOCKED, empty can also mean every remaining row was
            # locked elsewhere; either way the next discovery re-checks
            claim_cursors.clear(key, position)
          end

          claimed
        end

        def claim_candidates(relation, process_id, limit)
          candidates = nil

          claimed = transaction do
            candidates = select_candidates(relation, limit)
            Array(lock_candidates(candidates, process_id))
          end

          [ candidates, claimed ]
        end

        # Row-constructor index seeks and the motivating dead-tuple pathology
        # are PostgreSQL-specific.
        def claim_cursors_enabled?
          SolidQueue.claim_cursors && connection_db_config.adapter.match?(/postg/i)
        end

        def select_candidates(relation, limit)
          # Force query execution here with #to_a to avoid unintended FOR UPDATE query executions
          relation.ordered.limit(limit).non_blocking_lock.select(:id, :job_id, :priority).to_a
        end

        def lock_candidates(executions, process_id)
          return [] if executions.none?

          SolidQueue::ClaimedExecution.claiming(executions.map(&:job_id), process_id) do |claimed|
            ids_to_delete = executions.index_by(&:job_id).values_at(*claimed.map(&:job_id)).map(&:id)
            where(id: ids_to_delete).delete_all
          end
        end

        def position_of(execution)
          [ execution.priority, execution.id ] if execution
        end

        def discard_jobs(job_ids)
          Job.release_all_concurrency_locks Job.where(id: job_ids)
          super
        end
    end
  end
end
