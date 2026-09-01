# frozen_string_literal: true

module SolidQueue
  # App-side group commit for plain-job completions. Threads finishing at the
  # same time share one flush: the first to arrive becomes the leader, drains
  # everything pending into a single atomic statement, and wakes the rest.
  # Every thread blocks until its own completion is durable, so per-job
  # durability and the crash-replay window are identical to the per-job path —
  # only the fsync is shared.
  class CompletionCoordinator
    Entry = Struct.new(:execution_id, :job_id, :done, :error)

    class << self
      def instance
        @instance ||= new
      end

      def finish(execution) = instance.finish(execution)
    end

    def initialize
      @mutex = Mutex.new
      @cv = ConditionVariable.new
      @pending = []
      @flushing = false
    end

    def finish(execution)
      entry = Entry.new(execution.id, execution.job_id, false, nil)

      @mutex.synchronize do
        @pending << entry

        until entry.done
          if @flushing || @pending.empty?
            @cv.wait(@mutex)
          else
            lead_flush
          end
        end
      end

      raise entry.error if entry.error
    end

    private
      # Runs with the mutex held; releases it around the database work so
      # other completions can queue up behind this flush
      # How long the leader waits for stragglers before flushing. Bounded,
      # synchronous, and far below job latency noise — it trades sub-millisecond
      # completion latency for much larger shared-fsync groups.
      GATHER_WINDOW = 0.0004

      def lead_flush
        @flushing = true

        @mutex.unlock
        sleep GATHER_WINDOW
        @mutex.lock

        batch = @pending.dup
        @pending.clear

        @mutex.unlock
        begin
          error = nil
          begin
            flush_batch(batch)
          rescue => e
            error = e
          end
        ensure
          @mutex.lock
          @flushing = false
          batch.each { |entry| entry.done = true; entry.error = error }
          @cv.broadcast
        end
      end

      def flush_batch(batch)
        if ENV["GCSTATS"]
          @groups = (@groups || 0) + 1
          @grouped = (@grouped || 0) + batch.size
          at_exit { puts format("GROUPS: %d flushes, %.2f avg group size", @groups, @grouped.to_f / @groups) } if @groups == 1
        end
        execution_ids = batch.map(&:execution_id).join(",")
        connection = ClaimedExecution.connection
        connection.exec_update(<<~SQL)
          WITH deleted AS (
            DELETE FROM solid_queue_claimed_executions WHERE id IN (#{execution_ids}) RETURNING job_id
          )
          UPDATE solid_queue_jobs SET finished_at = now()
          WHERE id IN (SELECT job_id FROM deleted)
        SQL
      end
  end
end
