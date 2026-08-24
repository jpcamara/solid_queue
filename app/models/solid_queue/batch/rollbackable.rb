# frozen_string_literal: true

module SolidQueue
  class Batch
    # A batch created inside an application transaction is written on Solid Queue's
    # own connection, so when that's a different connection, the batch commits as
    # soon as it's enqueued and an application rollback never reaches it. The batch
    # row survives, and so does every job in it that wasn't deferred until commit.
    #
    # Maintenance can't tell such a batch from one whose creating process crashed
    # after enqueueing jobs, so it eventually starts it, finds nothing pending,
    # completes it, and fires its callbacks for work that was rolled back.
    #
    # Registering cleanup on the transactions the batch *doesn't* participate in
    # closes that gap: if any of them rolls back, the batch and its jobs go with it.
    # When Solid Queue shares the application's connection there's nothing to
    # register—the batch is already inside that transaction and rolls back with it.
    module Rollbackable
      extend ActiveSupport::Concern

      private
        def discard_if_enclosing_transactions_roll_back
          enclosing_transactions.each do |transaction|
            transaction.after_rollback { discard_after_rollback }
          end
        end

        # Open transactions the batch's own writes aren't part of. Comparing pools
        # rather than databases is deliberate: a queue database configured to point
        # at the same database as the app still gets its own connection, and so
        # still commits independently.
        # Rails 7.1 has no transaction rollback hooks, so batches there keep the
        # old behaviour: a rolled-back batch is left behind for maintenance.
        def enclosing_transactions
          return [] unless ActiveRecord.respond_to?(:all_open_transactions)

          ActiveRecord.all_open_transactions.reject { |transaction| transaction.connection.pool == self.class.connection_pool }
        end

        def discard_after_rollback
          SolidQueue.instrument(:discard_rolled_back_batch, batch_id: id, jobs: 0, claimed_jobs: 0) do |payload|
            payload[:claimed_jobs] = claimed_job_ids.size
            payload[:jobs] = discard_rolled_back_jobs
            Batch.where(id: id).delete_all
          end
        rescue ActiveRecord::ActiveRecordError => e
          SolidQueue.instrument(:discard_rolled_back_batch_error, batch_id: id, error: e)
        end

        # A job a worker already picked up can't be recalled, so leave it be: it's
        # reported in the instrumentation payload instead. Everything else goes,
        # and the executions cascade with it.
        def discard_rolled_back_jobs
          Job.where(batch_id: id).where.not(id: claimed_job_ids).destroy_all.size
        end

        def claimed_job_ids
          @claimed_job_ids ||= ClaimedExecution.where(job_id: Job.where(batch_id: id).select(:id)).pluck(:job_id)
        end
    end
  end
end
