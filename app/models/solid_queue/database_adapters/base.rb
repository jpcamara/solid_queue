# frozen_string_literal: true

module SolidQueue
  module DatabaseAdapters
    # Runs the code in the models that works on every database. Adapters for
    # particular databases override what they can do in fewer statements.
    class Base
      # Claims up to limit ready executions from queue_relation for the
      # process, skipping those locked elsewhere, and returns the claims.
      def claim(queue_relation, process_id, limit)
        ReadyExecution.claim_in_transaction(queue_relation, process_id, limit)
      end

      # Marks the claim's job finished and deletes the claim, unless the claim
      # is already gone. Returns whether it was there.
      def finish(claimed_execution)
        claimed_execution.finalize_claim { claimed_execution.job.finished! }
      end

      # Creates the job's execution of this kind, or finds the one it has.
      def create_execution(execution_class, job)
        execution_class.create_or_find_by!(job: job)
      end
    end
  end
end
