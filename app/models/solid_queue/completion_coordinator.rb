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

    # The first completion to arrive while no flush is running flushes
    # inline — no thread handoff. Completions arriving during a flush queue
    # up and are flushed by the next arrival (or themselves), so batches size
    # to flush latency with zero idle gaps.
    def finish(execution)
      return threaded_finish(execution) if adapter == :other

      my_batch = nil
      lead = false

      waiter = nil
      @mutex.synchronize do
        if @flushing
          waiter = Thread::Queue.new
          my_batch = (@pending ||= Batch.new([], []))
          my_batch.job_ids << execution.job_id
          my_batch.waiters << waiter
        else
          @flushing = true
          lead = true
          my_batch = Batch.new([ execution.job_id ], [])
          pending = @pending
          @pending = nil
          if pending
            my_batch.job_ids.concat(pending.job_ids)
            my_batch.waiters.concat(pending.waiters)
          end
        end
      end

      if lead
        error = lead_flush(my_batch)
        raise error if error
      else
        message = waiter.pop
        if message.is_a?(Batch)
          # Promoted: the previous leader handed us the batch our job is in
          error = lead_flush(message)
          raise error if error
        elsif message
          raise message
        end
      end
    end

    private
      # Single-writer databases do best with a single writer thread: pool
      # threads queue their completions and one flusher owns all the flushing
      def threaded_finish(execution)
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
            batch.waiters.each { |follower| follower.push(error) }
          end
        end
        @flusher.name = "solid_queue_completion_flusher"
      end

      # Flush one batch, then hand any batch that accumulated meanwhile to
      # one of its own waiters — no thread ever leads more than one flush,
      # and no dedicated thread sits idle between them
      def lead_flush(batch)
        error = nil
        begin
          flush(batch.job_ids)
        rescue => e
          error = e
        end

        next_batch = nil
        @mutex.synchronize do
          next_batch = @pending
          @pending = nil
          @flushing = false if next_batch.nil?
        end
        next_batch.waiters.shift.push(next_batch) if next_batch

        batch.waiters.each { |follower| follower.push(error) }
        error
      end

      # The flusher owns one connection for its whole life: no pool checkout
      # per flush, and on MySQL a multi-statement client sends the entire
      # atomic flush in a single round trip
      def flush(job_ids)
        ids = job_ids.join(",")

        case adapter
        when :postgresql
          flusher_ar_connection.exec_update(<<~SQL)
            WITH deleted AS (
              DELETE FROM solid_queue_claimed_executions WHERE job_id IN (#{ids}) RETURNING job_id
            )
            UPDATE solid_queue_jobs SET finished_at = now()
            WHERE id IN (SELECT job_id FROM deleted)
          SQL
        when :mysql
          now = Time.current.utc.strftime("'%Y-%m-%d %H:%M:%S.%6N'")
          client = flusher_mysql_client
          client.query(<<~SQL)
            BEGIN;
            DELETE FROM solid_queue_claimed_executions WHERE job_id IN (#{ids});
            UPDATE solid_queue_jobs SET finished_at = #{now} WHERE id IN (#{ids});
            COMMIT
          SQL
          client.next_result while client.next_result
        else
          connection = flusher_ar_connection
          now = connection.quote(Time.current)
          SqliteWriterFunnel.acquire(ClaimedExecution.connection_pool) do
            connection.transaction do
              connection.execute("DELETE FROM solid_queue_claimed_executions WHERE job_id IN (#{ids})")
              connection.execute("UPDATE solid_queue_jobs SET finished_at = #{now} WHERE id IN (#{ids})")
            end
          end
        end
      end

      def adapter
        @adapter ||= case ClaimedExecution.connection_pool.db_config.adapter
        when "postgresql" then :postgresql
        when /mysql/ then :mysql
        else :other
        end
      end

      def flusher_ar_connection
        @flusher_ar_connection ||= ClaimedExecution.connection_pool.checkout
      end

      def flusher_mysql_client
        @flusher_mysql_client ||= begin
          config = ClaimedExecution.connection_pool.db_config.configuration_hash
          Mysql2::Client.new(config.merge(flags: Mysql2::Client::MULTI_STATEMENTS))
        end
      end
  end
end
