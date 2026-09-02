# frozen_string_literal: true

require "singleton"

module SolidQueue
  # Group commit for plain-job completions, driven by a dedicated flusher
  # thread per process. Completing threads enqueue their job and block until
  # the flusher has committed their batch, so per-job durability and the
  # crash-replay window are identical to the per-job path. The flusher drains
  # everything pending into one atomic flush per cycle, which sizes batches
  # to the flush latency automatically and keeps claiming and flushing
  # overlapped instead of convoying.
  class CompletionCoordinator
    include Singleton

    Batch = Struct.new(:job_ids, :waiters)

    class << self
      def finish(execution) = instance.finish(execution)
    end

    def initialize
      @mutex = Mutex.new
      @work = Thread::Queue.new
      @pending = nil
      @flushing = 0
      # Written by one leader at a time and read racily by arriving threads;
      # any recently written value is valid, so an atomic reference is all
      # the synchronization the pace needs
      @flush_pace = Concurrent::AtomicReference.new(0.0)
    end

    # The first completion to arrive while no flush is running flushes
    # inline — no thread handoff. Completions arriving during a flush queue
    # up and are flushed by the next arrival (or themselves), so batches size
    # to flush latency with zero idle gaps.
    def finish(execution)
      return threaded_finish(execution) if adapter.dedicated_flusher?

      my_batch = nil
      lead = false

      waiter = nil
      @mutex.synchronize do
        if @flushing >= max_inflight_flushes
          # A reused thread-local queue outperforms a promise per completion
          # at queue throughput rates — measured, not assumed: promise-based
          # dispatch was removed from this hot path for exactly that reason
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

      def flush_pace
        @flush_pace.get
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
        pace = flush_pace
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
        previous = @flush_pace.get
        @flush_pace.set(previous.zero? ? duration : previous * 0.8 + duration * 0.2)
      end

      # Single-writer databases do best with a single writer thread: pool
      # threads push their completions onto a queue and one flusher owns all
      # the flushing, draining whatever has accumulated into each batch
      def threaded_finish(execution)
        ensure_flusher
        waiter = (Thread.current[:sq_completion_waiter] ||= Thread::Queue.new)
        @work.push([ execution.job_id, waiter ])
        error = waiter.pop
        raise error if error
      end

      def ensure_flusher
        return if @flusher&.alive?

        @mutex.synchronize do
          next if @flusher&.alive?

          @flusher = Thread.new do
            loop do
              entries = [ @work.pop ]
              entries << @work.pop until @work.empty?

              error = nil
              begin
                flush(entries.map(&:first))
              rescue => e
                error = e
              end
              entries.each { |_, waiter| waiter.push(error) }
            end
          end
          @flusher.name = "solid_queue_completion_flusher"
        end
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

      # Each batch flushes atomically through the database adapter: either
      # the whole batch is durable and finished, or none of it is
      def flush(job_ids)
        adapter.flush_completions(job_ids)
      end

      def adapter
        @adapter ||= DatabaseAdapter.resolve
      end
  end
end
