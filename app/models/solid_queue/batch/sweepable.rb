# frozen_string_literal: true

module SolidQueue
  class Batch
    # Repairs batches that the regular completion detection can't finish on its
    # own: jobs removed via bulk discards, or completions whose callback
    # enqueueing failed and rolled back.
    #
    # Repair here never invents state. A batch is only completed once its creator
    # sealed it by calling #start, because "sealed" is the only thing that makes
    # an empty batch meaningfully complete rather than merely unfilled. Batches
    # that were never sealed are reported, not finished—see #report_stalled_batches.
    module Sweepable
      extend ActiveSupport::Concern

      included do
        scope :unsealed, -> { unfinished.where(enqueued_at: nil) }
      end

      class_methods do
        def sweep_stalled(stalled_for: 5.minutes, batch_size: 500)
          SolidQueue.instrument(:sweep_stalled_batches, stalled_for: stalled_for, stale_executions: 0, finished_batches: 0, stalled_batches: 0) do |payload|
            payload[:stale_executions] = sweep_stale_executions(batch_size:)
            payload[:finished_batches] = finish_stalled_batches(batch_size:)
            payload[:stalled_batches] = report_stalled_batches(stalled_for:, batch_size:)
          end
        end

        # Batches their creator never sealed, and hasn't sealed for a while. Use
        # this to find them, and SolidQueue::Batch#start to adopt one deliberately
        # once you've established its creator is gone for good.
        def stalled(stalled_for: 5.minutes)
          unsealed.where(created_at: ...stalled_for.ago)
        end

        private
          # BatchExecution rows represent outstanding work. A row for a resolved
          # job violates that invariant, so remove it immediately; destroy's
          # after_commit callback retries the batch completion check.
          def sweep_stale_executions(batch_size:)
            swept = 0

            [ BatchExecution.with_finished_jobs, BatchExecution.with_failed_jobs ].each do |stale|
              stale.find_each(batch_size: batch_size) do |batch_execution|
                swept += 1
                batch_execution.destroy
              end
            end

            swept
          end

          # A sealed batch with no tracking rows left can finish. Sealed is the
          # load-bearing word: its creator got far enough to declare the batch
          # complete, so an empty one really is done.
          def finish_stalled_batches(batch_size:)
            finished = 0

            unfinished.enqueued.without_executions.find_each(batch_size: batch_size) do |batch|
              finished += 1
              batch.finish
            end

            finished
          end

          # Batches created outside any transaction seal in the same write as
          # their row, so a crashed creator can't leave one behind. An unsealed
          # batch therefore came from inside a transaction—one still filling it,
          # rolled back, or died uncommitted—or is still waiting on deferred
          # enqueues. Completing any of those loses work: the batch finishes
          # with whatever happened to have landed, fires its callbacks, and the
          # real enqueues then raise AlreadyFinished. Since "still coming" and
          # "never coming" are indistinguishable here, report them and let an
          # operator decide, rather than guessing and reporting success for
          # work that never ran.
          def report_stalled_batches(stalled_for:, batch_size:)
            stalled_batches = stalled(stalled_for: stalled_for)
            count = stalled_batches.count
            return 0 if count.zero?

            stalled_batches.find_each(batch_size: batch_size) do |batch|
              SolidQueue.instrument(:stalled_batch, batch_id: batch.id, created_at: batch.created_at, total_jobs: batch.total_jobs)
            end

            count
          end
      end
    end
  end
end
