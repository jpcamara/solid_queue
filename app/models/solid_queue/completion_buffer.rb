# frozen_string_literal: true

module SolidQueue
  # Groups successful completions of plain jobs into one transaction, the way
  # claiming already groups claims. Failures, concurrency-limited jobs and
  # batched jobs keep the per-job path: their finalization has side effects
  # (retries, semaphores, batch tracking callbacks) that update_all would skip.
  #
  # Trade: a crash loses the buffered (already-executed) completions, so those
  # jobs re-run on recovery — the same at-least-once contract as today, with
  # the window widened from one job to at most +flush_threshold+ jobs.
  class CompletionBuffer
    FLUSH_THRESHOLD = 50

    class << self
      def instance
        @instance ||= new
      end

      def add(execution) = instance.add(execution)
      def flush = instance.flush
    end

    def initialize(threshold: FLUSH_THRESHOLD)
      @threshold = threshold
      @mutex = Mutex.new
      @pending = []
    end

    def add(execution)
      to_flush = @mutex.synchronize do
        @pending << [ execution.id, execution.job_id ]
        @pending.size >= @threshold ? @pending.dup.tap { @pending.clear } : nil
      end
      flush_batch(to_flush) if to_flush
    end

    def flush
      to_flush = @mutex.synchronize { @pending.dup.tap { @pending.clear } }
      flush_batch(to_flush) if to_flush.any?
    end

    private
      def flush_batch(entries)
        execution_ids = entries.map(&:first)
        job_ids = entries.map(&:last)

        ClaimedExecution.transaction do
          ClaimedExecution.where(id: execution_ids).delete_all
          if SolidQueue.preserve_finished_jobs?
            Job.where(id: job_ids).update_all(finished_at: Time.current)
          else
            Job.where(id: job_ids).delete_all
          end
        end
      end
  end
end
