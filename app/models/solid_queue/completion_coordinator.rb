# frozen_string_literal: true

module SolidQueue
  # App-side group commit for plain-job completions. Completions arriving
  # together share one atomic flush; each thread blocks until its own group is
  # durable, so per-job durability and the crash-replay window are identical
  # to the per-job path. Groups flush concurrently on their leaders' own
  # connections — a group never queues behind the previous one.
  class CompletionCoordinator
    # How long a group stays open for stragglers before its leader flushes.
    # Bounded, synchronous latency traded for larger shared fsyncs.
    GATHER_WINDOW = 0.0003

    class Group
      attr_reader :entries, :cv
      attr_accessor :done, :error

      def initialize
        @entries = []
        @cv = ConditionVariable.new
        @done = false
        @error = nil
      end
    end

    class << self
      def instance
        @instance ||= new
      end

      def finish(execution) = instance.finish(execution)
    end

    def initialize
      @mutex = Mutex.new
      @open_group = nil
    end

    def finish(execution)
      group = nil
      leader = false

      @mutex.synchronize do
        if @open_group
          group = @open_group
        else
          group = @open_group = Group.new
          leader = true
        end
        group.entries << [ execution.id, execution.job_id ]
      end

      if leader
        sleep GATHER_WINDOW

        batch = nil
        @mutex.synchronize do
          @open_group = nil if @open_group.equal?(group)
          batch = group.entries.dup
        end

        error = nil
        begin
          flush(batch)
        rescue => e
          error = e
        end

        @mutex.synchronize do
          group.done = true
          group.error = error
          group.cv.broadcast
        end
        raise error if error
      else
        @mutex.synchronize do
          group.cv.wait(@mutex) until group.done
        end
        raise group.error if group.error
      end
    end

    private
      def flush(batch)
        execution_ids = batch.map(&:first).join(",")
        ClaimedExecution.connection.exec_update(<<~SQL)
          WITH deleted AS (
            DELETE FROM solid_queue_claimed_executions WHERE id IN (#{execution_ids}) RETURNING job_id
          )
          UPDATE solid_queue_jobs SET finished_at = now()
          WHERE id IN (SELECT job_id FROM deleted)
        SQL
      end
  end
end
