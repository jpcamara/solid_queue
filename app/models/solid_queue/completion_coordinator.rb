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
        if @flushing >= max_inflight_flushes
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
      # In-flight flushes adapt to what commits cost. When commits are cheap
      # (fast or write-cached fsync), one leader building large batches wins:
      # concurrent leaders would only split arrivals. When commits are
      # expensive (real FLUSH per fsync, milliseconds each), each leader
      # first collects a window proportional to the flush cost — so batches
      # stay whole — and just enough leaders run concurrently to keep a
      # flush always in flight while the next batch collects. The database
      # absorbs the overlapping commits into shared group commits.
      # Measured on both cheap-fsync (macOS) and real-fsync (Linux consumer
      # NVMe) hardware: extra concurrent flushes only split batches, because
      # the database's commit path is a shared serial resource — throughput
      # is fsync groups per second times jobs per group. One leader with a
      # cost-scaled collect window maximizes jobs per group.
      MAX_INFLIGHT_FLUSHES = 1
      CHEAP_FLUSH = 0.002

      def max_inflight_flushes
        MAX_INFLIGHT_FLUSHES
      end

      def collect_window_for(pace)
        if pace < CHEAP_FLUSH
          pace > 0.0012 ? 0.0012 : pace
        else
          half = pace / 2
          half > 0.01 ? 0.01 : half
        end
      end

      # Group-commit collection: a fresh leader waits one flush-duration
      # (measured, not guessed) before flushing, so completions from the same
      # claim burst commit together instead of one commit each. Promoted
      # leaders flush back-to-back and their batches size themselves.
      def pace_and_collect(my_batch)
        pace = @flush_pace
        return unless pace > 0

        if pace < CHEAP_FLUSH
          sleep(collect_window_for(pace))
        else
          # When flushes are expensive the whole in-flight burst should share
          # one commit: keep collecting in 1ms slices while completions are
          # still arriving, up to half the flush duration
          deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + collect_window_for(pace)
          last_size = -1
          loop do
            sleep(0.001)
            size = @pending&.job_ids&.size || 0
            break if size == last_size
            last_size = size
            break if ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) >= deadline
          end
        end

        @mutex.synchronize do
          if (joined = @pending)
            @pending = nil
            my_batch.job_ids.concat(joined.job_ids)
            my_batch.waiters.concat(joined.waiters)
          end
        end
      end

      def record_flush_pace(started, finished)
        duration = finished - started
        @flush_pace = @flush_pace.zero? ? duration : @flush_pace * 0.8 + duration * 0.2
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
            client.query("BEGIN")
            client.query("DELETE FROM solid_queue_claimed_executions WHERE job_id IN (#{ids})")
            client.query("UPDATE solid_queue_jobs SET finished_at = #{now} WHERE id IN (#{ids})")
            client.query("COMMIT")
          rescue Mysql2::Error
            begin client.query("ROLLBACK"); rescue Mysql2::Error; end
            raise
          end
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
          Mysql2::Client.new(config)
        end
      end
  end
end
