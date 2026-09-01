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
      @flushing = 0
      @pool_mutex = Mutex.new
      @flusher_pool = Thread::Queue.new
      @flusher_pool_size = 0
      @flush_pace = 0.0
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
        if @flushing >= MAX_INFLIGHT_FLUSHES
          waiter = (Thread.current[:sq_completion_waiter] ||= Thread::Queue.new)
          my_batch = (@pending ||= Batch.new([], []))
          my_batch.job_ids << execution.job_id
          my_batch.waiters << waiter
        else
          @flushing += 1
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
        pace_and_collect(my_batch)
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
      # One flush in flight per process: concurrent leaders split arrivals
      # into smaller batches, and measured throughput drops on every adapter
      MAX_INFLIGHT_FLUSHES = 1

      # Group-commit collection: a fresh leader waits one flush-duration
      # (measured, not guessed) before flushing, so completions from the same
      # claim burst commit together instead of one commit each. Promoted
      # leaders flush back-to-back and their batches size themselves.
      def pace_and_collect(my_batch)
        return unless @flush_pace > 0

        sleep(@flush_pace)
        @mutex.synchronize do
          if (joined = @pending)
            @pending = nil
            my_batch.job_ids.concat(joined.job_ids)
            my_batch.waiters.concat(joined.waiters)
          end
        end
      end

      MAX_FLUSH_PACE = 0.0012

      def record_flush_pace(started, finished)
        duration = finished - started
        pace = @flush_pace.zero? ? duration : @flush_pace * 0.8 + duration * 0.2
        @flush_pace = pace > MAX_FLUSH_PACE ? MAX_FLUSH_PACE : pace
      end

      # Single-writer databases do best with a single writer thread: pool
      # threads queue their completions and one flusher owns all the flushing
      def threaded_finish(execution)
        waiter = (Thread.current[:sq_completion_waiter] ||= Thread::Queue.new)
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
        started = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
        begin
          flush(batch.job_ids)
        rescue => e
          error = e
        end
        record_flush_pace(started, ::Process.clock_gettime(::Process::CLOCK_MONOTONIC))

        next_batch = nil
        @mutex.synchronize do
          next_batch = @pending
          @pending = nil
          @flushing -= 1 if next_batch.nil?
        end
        next_batch.waiters.shift.push(next_batch) if next_batch

        batch.waiters.each { |follower| follower.push(error) }
        error
      end

      # Flushers own persistent raw connections, one per in-flight flush: no
      # pool checkout per flush, and on MySQL a multi-statement client sends
      # the entire atomic flush in a single round trip
      def flush(job_ids)
        ids = job_ids.join(",")

        case adapter
        when :postgresql
          with_flusher_connection do |conn|
            conn.exec(<<~SQL)
              WITH deleted AS (
                DELETE FROM solid_queue_claimed_executions WHERE job_id IN (#{ids}) RETURNING job_id
              )
              UPDATE solid_queue_jobs SET finished_at = now()
              WHERE id IN (SELECT job_id FROM deleted)
            SQL
          end
        when :mysql
          now = Time.current.utc.strftime("'%Y-%m-%d %H:%M:%S.%6N'")
          with_flusher_connection do |client|
            client.query(<<~SQL)
              BEGIN;
              DELETE FROM solid_queue_claimed_executions WHERE job_id IN (#{ids});
              UPDATE solid_queue_jobs SET finished_at = #{now} WHERE id IN (#{ids});
              COMMIT
            SQL
            client.next_result while client.next_result
          end
        else
          connection = flusher_ar_connection
          @sqlite_delete_stmt ||= connection.raw_connection.prepare("DELETE FROM solid_queue_claimed_executions WHERE job_id IN (SELECT value FROM json_each(?))")
          @sqlite_update_stmt ||= connection.raw_connection.prepare("UPDATE solid_queue_jobs SET finished_at = ? WHERE id IN (SELECT value FROM json_each(?))")
          ids_json = "[#{ids}]"
          now = connection.quoted_date(Time.current)
          SqliteWriterFunnel.acquire(ClaimedExecution.connection_pool) do
            connection.transaction do
              @sqlite_delete_stmt.execute(ids_json).to_a
              @sqlite_update_stmt.execute(now, ids_json).to_a
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

      def with_flusher_connection
        conn = nil
        @pool_mutex.synchronize do
          if @flusher_pool.empty? && @flusher_pool_size < MAX_INFLIGHT_FLUSHES
            @flusher_pool_size += 1
            conn = new_flusher_connection
          end
        end
        conn ||= @flusher_pool.pop
        begin
          yield conn
        ensure
          @flusher_pool.push(conn)
        end
      end

      def new_flusher_connection
        config = ClaimedExecution.connection_pool.db_config.configuration_hash

        if adapter == :postgresql
          PG.connect({ dbname: config[:database], host: config[:host], port: config[:port],
                       user: config[:username], password: config[:password] }.compact)
        else
          Mysql2::Client.new(config.merge(flags: Mysql2::Client::MULTI_STATEMENTS))
        end
      end
  end
end
