# frozen_string_literal: true

module SolidQueue
  # Group commit for plain-job completions, driven by a dedicated flusher
  # thread per process. Completing threads enqueue their job and block until
  # the flusher has committed their batch, so per-job durability and the
  # crash-replay window are identical to the per-job path. The flusher drains
  # everything pending into one atomic flush per cycle, which sizes batches
  # to the flush latency automatically and keeps claiming and flushing
  # overlapped instead of convoying.
  class CompletionCoordinator
    Batch = Struct.new(:job_ids, :waiters)

    class << self
      def instance
        @instance ||= new
      end

      def finish(execution) = instance.finish(execution)
    end

    def initialize
      @mutex = Mutex.new
      @work_cv = ConditionVariable.new
      @pending = nil
    end

    def finish(execution)
      waiter = Thread::Queue.new
      @mutex.synchronize do
        ensure_flusher
        batch = (@pending ||= Batch.new([], []))
        batch.job_ids << execution.job_id
        batch.waiters << waiter
        @work_cv.signal
      end

      error = waiter.pop
      raise error if error
    end

    private
      def ensure_flusher
        return if @flusher&.alive?

        @flusher = Thread.new do
          loop do
            batch = nil
            @mutex.synchronize do
              @work_cv.wait(@mutex) while @pending.nil?
              batch = @pending
              @pending = nil
            end

            error = nil
            begin
              flush(batch.job_ids)
            rescue => e
              error = e
            end

            batch.waiters.each { |waiter| waiter.push(error) }
          end
        end
        @flusher.name = "solid_queue_completion_flusher"
      end

      def flush(job_ids)
        if ClaimedExecution.connection_pool.db_config.adapter == "postgresql"
          ids = job_ids.join(",")
          ClaimedExecution.connection_pool.with_connection do |connection|
            connection.exec_update(<<~SQL)
              WITH deleted AS (
                DELETE FROM solid_queue_claimed_executions WHERE job_id IN (#{ids}) RETURNING job_id
              )
              UPDATE solid_queue_jobs SET finished_at = now()
              WHERE id IN (SELECT job_id FROM deleted)
            SQL
          end
        else
          ids = job_ids.join(",")
          ClaimedExecution.connection_pool.with_connection do |connection|
            ClaimedExecution.transaction do
              connection.execute("DELETE FROM solid_queue_claimed_executions WHERE job_id IN (#{ids})")
              connection.execute("UPDATE solid_queue_jobs SET finished_at = #{connection.quote(Time.current)} WHERE id IN (#{ids})")
            end
          end
        end
      end
  end
end
