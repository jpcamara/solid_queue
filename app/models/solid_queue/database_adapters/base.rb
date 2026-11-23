# frozen_string_literal: true

module SolidQueue
  module DatabaseAdapters
    class Base
      # Claims up to limit ready executions from queue_relation for the
      # process, skipping those locked elsewhere, and returns the claims.
      def claim(queue_relation, process_id, limit)
        ReadyExecution.transaction do
          candidates = select_candidates(queue_relation, limit)
          lock_candidates(candidates, process_id)
        end
      end

      # Marks the claim's job finished and deletes the claim, unless the claim
      # is already gone. Returns whether it was there.
      def finish(claimed_execution)
        claimed_execution.finalize_claim { claimed_execution.job.finished! }
      end

      private
        def select_candidates(queue_relation, limit)
          # Force query execution here with #to_a to avoid unintended FOR UPDATE query executions
          queue_relation.ordered.limit(limit).non_blocking_lock.select(:id, :job_id).to_a
        end

        def lock_candidates(executions, process_id)
          return [] if executions.none?

          ClaimedExecution.claiming(executions.map(&:job_id), process_id) do |claimed|
            ids_to_delete = executions.index_by(&:job_id).values_at(*claimed.map(&:job_id)).map(&:id)
            ReadyExecution.where(id: ids_to_delete).delete_all
          end
        end
    end
  end
end
