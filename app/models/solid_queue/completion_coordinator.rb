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
      attr_reader :entries, :cv, :leader_cv
      attr_accessor :done, :error, :sealed

      def initialize
        @entries = []
        @cv = ConditionVariable.new
        @leader_cv = ConditionVariable.new
        @done = false
        @sealed = false
        @error = nil
      end
    end

    class << self
      # Hint from the worker: a group this large has everyone on board, so its
      # leader can flush without waiting out the gather window
      attr_accessor :target_group_size
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

      target = self.class.target_group_size
      @mutex.synchronize do
        if @open_group
          group = @open_group
        else
          group = @open_group = Group.new
          leader = true
        end
        group.entries << execution.job_id
        group.leader_cv.signal if !leader && target && group.entries.size >= target
      end

      if leader
        batch = nil
        @mutex.synchronize do
          unless target && group.entries.size >= target
            group.leader_cv.wait(@mutex, GATHER_WINDOW)
          end
          group.sealed = true
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
      def flush(job_ids)
        if ClaimedExecution.connection.adapter_name == "PostgreSQL"
          ids = job_ids.join(",")
          ClaimedExecution.connection.exec_update(<<~SQL)
            WITH deleted AS (
              DELETE FROM solid_queue_claimed_executions WHERE job_id IN (#{ids}) RETURNING job_id
            )
            UPDATE solid_queue_jobs SET finished_at = now()
            WHERE id IN (SELECT job_id FROM deleted)
          SQL
        else
          ClaimedExecution.transaction do
            ClaimedExecution.where(job_id: job_ids).delete_all
            Job.where(id: job_ids).update_all(finished_at: Time.current)
          end
        end
      end
  end
end
