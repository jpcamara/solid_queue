# frozen_string_literal: true

module SolidQueue
  class BatchExecution < Execution
    self.assumable_attributes_from_job = [ :batch_id ]

    belongs_to :batch

    scope :with_finished_jobs, -> { joins(:job).merge(SolidQueue::Job.finished) }
    scope :with_failed_jobs, -> { joins(job: :failed_execution) }

    after_commit :finish_batch, on: :destroy

    class << self
      def create_all_from_jobs(jobs)
        jobs.select(&:batched?).group_by(&:batch_id).each do |batch_id, jobs_in_batch|
          if counting_for?(batch_id)
            pending_counts[batch_id] += count_new_jobs_among(jobs_in_batch)
            super jobs_in_batch
          # Update the counter first: inserting tracking rows takes a shared FK lock on
          # the batch row, then incrementing can deadlock concurrent MySQL adders.
          elsif attempt_to_update_total_jobs(batch_id, jobs_in_batch)
            pending_counts[batch_id] = 0 if counting_here?
            super jobs_in_batch
          else
            raise Batch::AlreadyFinished, "Can't add jobs into an already finished batch"
          end
        end
      end

      # Counts the jobs added to batches in the block, which must run in a
      # transaction, with one update per batch instead of one per job. The
      # first job added to a batch still updates its counter, which checks
      # that the batch isn't finished and locks it until commit, so the jobs
      # after it only need counting. Jobs added in a nested transaction or
      # savepoint, which could roll back on its own, update the counter themselves.
      def counting_jobs
        transaction = current_transaction
        if counting || !transaction.open? then yield
        else
          begin
            ActiveSupport::IsolatedExecutionState[:solid_queue_batch_counts] = { transaction: transaction, counts: Hash.new(0) }
            yield.tap { update_pending_counts }
          ensure
            ActiveSupport::IsolatedExecutionState.delete(:solid_queue_batch_counts)
          end
        end
      end

      private
        def counting
          ActiveSupport::IsolatedExecutionState[:solid_queue_batch_counts]
        end

        def pending_counts
          counting[:counts]
        end

        def counting_here?
          counting && counting[:transaction].equal?(current_transaction)
        end

        def counting_for?(batch_id)
          counting_here? && pending_counts.key?(batch_id)
        end

        def current_transaction
          connection_pool.with_connection(&:current_transaction)
        end

        def update_pending_counts
          pending_counts.each do |batch_id, count|
            SolidQueue::Batch.where(id: batch_id).update_all([ "total_jobs = total_jobs + ?", count ]) if count > 0
          end
        end

        def attempt_to_update_total_jobs(batch_id, jobs)
          new_jobs_count = count_new_jobs_among(jobs)
          updated = SolidQueue::Batch.where(id: batch_id).unfinished.update_all([ "total_jobs = total_jobs + ?", new_jobs_count ])
          updated > 0
        end

        # A job that has executed before was already counted when it first joined
        # the batch: retries keep their active_job_id and batch across re-enqueues.
        # This might undercount jobs whose retries switch to another batch, but that
        # should be a rare enough case. The counter is used only for report/info, so
        # we favour simplicity here
        def count_new_jobs_among(jobs)
          jobs.reject { |job| job.arguments["executions"].to_i > 0 }.map(&:active_job_id).uniq.size
        end
    end

    private
      def finish_batch
        # Skip the serialized callback and metadata columns on this hot path
        if batch = Batch.select(:id, :finished_at, :enqueued_at).find_by(id: batch_id)
          batch.finish
        end
      end
  end
end
