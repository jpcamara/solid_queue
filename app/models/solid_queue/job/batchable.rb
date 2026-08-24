# frozen_string_literal: true

module SolidQueue
  class Job
    module Batchable
      extend ActiveSupport::Concern

      included do
        belongs_to :batch, optional: true
        has_one :batch_execution

        after_create :create_batch_execution, if: :batched?
        after_update :update_batch_progress, if: :batched?
        after_commit :finish_batch_after_progress, on: :update
        before_destroy :destroy_batch_execution, if: :batched?
      end

      class_methods do
        def batch_all(jobs)
          BatchExecution.create_all_from_jobs(jobs) if Batch.migrated?
        end
      end

      # Also guards against the batches schema not being installed: without
      # its migration, jobs don't even have a batch_id.
      def batched?
        Batch.migrated? && batch_id?
      end

      private
        def create_batch_execution
          BatchExecution.create_all_from_jobs([ self ])
        end

        # The tracking row is deleted by key rather than loaded and destroyed:
        # a finishing job already knows which row is its own. Completion is then
        # checked from this job's own after_commit, which runs at the same point
        # the tracking row's would have.
        def update_batch_progress
          return unless saved_change_to_finished_at? && finished_at.present?

          @batch_execution_removed = BatchExecution.where(job_id: id).delete_all.positive?
        rescue ActiveRecord::ActiveRecordError => e
          SolidQueue.instrument(:batch_progress_error, batch_id: batch_id, job_id: id, error: e)
        end

        def finish_batch_after_progress
          return unless @batch_execution_removed

          @batch_execution_removed = false
          BatchExecution.finish_batch_for(batch_id)
        rescue ActiveRecord::ActiveRecordError => e
          SolidQueue.instrument(:batch_progress_error, batch_id: batch_id, job_id: id, error: e)
        end

        # Destroy through Active Record instead of relying on the foreign
        # key's cascade, so destroying the tracking row retries the batch
        # completion check.
        def destroy_batch_execution
          batch_execution&.destroy!
        end
    end
  end
end
