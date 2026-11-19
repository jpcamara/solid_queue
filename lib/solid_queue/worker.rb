# frozen_string_literal: true

module SolidQueue
  class Worker < Processes::Poller
    include LifecycleHooks

    after_boot :run_start_hooks
    before_shutdown :run_stop_hooks
    after_shutdown :run_exit_hooks

    attr_reader :queues, :pool, :prefetch

    def initialize(**options)
      execution_pool_type = options.key?(:fibers) ? :fiber : :thread

      options = options.dup.with_defaults(SolidQueue::Configuration::WORKER_DEFAULTS)
      execution_pool_size = execution_pool_type == :fiber ? options[:fibers] : options[:threads]

      # Ensure that the queues array is deep frozen to prevent accidental modification
      @queues = Array(options[:queues]).map(&:freeze).freeze

      @prefetch = options[:prefetch].to_i.clamp(0..)
      @prefetched = []
      @prefetched_mutex = Mutex.new
      @giving_back = []
      @ahead = 0
      @completed = 0

      @pool = Pool.build \
        type: execution_pool_type,
        size: execution_pool_size,
        on_idle: -> { post_prefetched_on_idle },
        on_unrecoverable_error: -> { request_termination }

      super(**options)
    end

    def metadata
      super.merge(queues: queues.join(","), pool_type: pool.type, pool_size: pool.size, prefetch: prefetch)
    end

    private
      # A job claimed ahead of a free thread or fiber, and when it was claimed
      Prefetched = Struct.new(:execution, :claimed_at)

      attr_reader :prefetched, :prefetched_mutex, :giving_back, :ahead

      def poll
        give_back_prefetched_waiting_too_long
        return polling_interval if giving_back.any?

        measure_pace

        # Keep polling while holding prefetched jobs, to give them back if they wait too long
        return polling_interval if ahead > 0 && prefetched_enough?

        limit = claim_limit
        return (prefetched.any? ? polling_interval : 10.minutes) unless limit.positive?

        claim_executions(limit).then do |executions|
          # Keep claiming ahead while claims come back full, as the queues are deep
          @claiming_ahead = ahead > 0 && executions.any? && executions.size == limit

          add_to_prefetched(executions)
          post_prefetched

          if claiming_ahead? && prefetched.size < ahead then 0
          elsif pool.idle? || prefetched.any? then polling_interval
          else 10.minutes
          end
        end
      end

      def claim_limit
        if claiming_ahead?
          pool.available_capacity + ahead - prefetched.size
        else
          pool.available_capacity
        end
      end

      def claim_executions(limit)
        with_polling_volume do
          SolidQueue::ReadyExecution.claim(queues, limit, process_id)
        end
      end

      def claiming_ahead?
        @claiming_ahead
      end

      # The worker claims again only once it holds less than half of what it claims ahead,
      # so that every claim brings more than half of it
      def prefetched_enough?(held = prefetched.size)
        held > 0 && held * 2 >= ahead
      end

      # Jobs start in the order of their claimed executions' ids, so the claims a worker holds
      # beyond the size of its pool are always the ones it hasn't started. That's how they are
      # told apart when the worker dies (see Process::Executor), which relies on ids growing
      # with every claim, as they do with autoincrementing primary keys.
      def add_to_prefetched(executions)
        claimed_at = monotonic_now

        prefetched_mutex.synchronize do
          executions.sort_by(&:id).each do |execution|
            prefetched << Prefetched.new(execution, claimed_at)
          end
        end

        check_claims_keep_their_order(executions) if prefetch > 0
      end

      # If ids didn't grow with every claim, as with a sequence that caches values per
      # connection, prefetched jobs couldn't be told apart, so the worker stops prefetching
      def check_claims_keep_their_order(executions)
        ids = executions.map(&:id)

        if ids.any? && @last_claimed_id && ids.min < @last_claimed_id
          SolidQueue.logger&.warn("Claimed execution ids don't grow with every claim, so worker #{name} stops prefetching")
          stop_prefetching
          @prefetch = 0
        end

        @last_claimed_id = [ @last_claimed_id, *ids ].compact.max
      end

      # A prefetched job that has waited longer than the polling interval isn't started: the
      # next poll gives it back, with the ones claimed after it. A worker stalled for as long as
      # it takes to be pruned has had them released already, and other workers may run them.
      def post_prefetched
        prefetched_mutex.synchronize do
          while prefetched.any? && pool.idle? && !waited_too_long?(prefetched.first)
            pool.post(prefetched.shift.execution)
          end

          prefetched.size
        end
      end

      # Runs in the pool when a thread or fiber becomes free: it hands it the next
      # prefetched job, if any, and wakes the worker to claim more when needed
      def post_prefetched_on_idle
        # A post that the pool rejects because it's shutting down gives back the capacity it took,
        # which comes back here, on the same thread, from within post_prefetched
        return if prefetched_mutex.owned?

        prefetched_mutex.synchronize { @completed += 1 }
        remaining = post_prefetched unless stopped? || pool.shutdown?
      ensure
        wake_up unless remaining && prefetched_enough?(remaining)
      end

      # Claim ahead as many jobs as the pool finishes in half the polling interval, up
      # to `prefetch`, so that prefetched jobs don't wait for long. With jobs that take
      # longer than that, the worker doesn't claim ahead at all.
      def measure_pace
        return if prefetch.zero?

        now, completed = monotonic_now, prefetched_mutex.synchronize { @completed }

        if @pace_measured_at.nil?
          @pace_measured_at, @completed_when_measured = now, completed
        elsif (elapsed = now - @pace_measured_at) >= polling_interval
          @ahead = ((completed - @completed_when_measured) * polling_interval / 2 / elapsed).floor.clamp(0, prefetch)
          @pace_measured_at, @completed_when_measured = now, completed
        end
      end

      # Prefetched jobs that have waited longer than the polling interval go back to
      # their queues, where idle workers can claim them, and the worker stops claiming
      # ahead until it measures its pace again
      def give_back_prefetched_waiting_too_long
        stop_prefetching if prefetched_waiting_too_long?

        while execution = giving_back.first
          execution.release
          giving_back.shift
        end
      rescue => error
        # The claims stay with this worker until they can be given back, and it doesn't
        # claim more meanwhile, so that the ones it has started keep the lowest ids
        handle_thread_error(error)
      end

      def prefetched_waiting_too_long?
        oldest = prefetched_mutex.synchronize { prefetched.first }
        oldest.present? && waited_too_long?(oldest)
      end

      def waited_too_long?(prefetched_job)
        prefetched_job.claimed_at < monotonic_now - polling_interval
      end

      def stop_prefetching
        giving_back.concat(prefetched_mutex.synchronize { prefetched.slice!(0..) }.map(&:execution))
        @ahead, @claiming_ahead, @pace_measured_at = 0, false, nil
      end

      def monotonic_now
        SolidQueue::Timer.monotonic_time_now
      end

      def request_termination
        # Signal the poller to shut down without joining from the pool thread.
        # Runnable#stop joins when unsupervised, which would deadlock once
        # shutdown waits for this pool thread to finish.
        @stopped = true
        wake_up
      end

      def shutdown
        pool.shutdown
        pool.wait_for_termination(SolidQueue.shutdown_timeout)

        super
      end

      def all_work_completed?
        prefetched.empty? && SolidQueue::ReadyExecution.aggregated_count_across(queues).zero?
      end

      def set_procline
        procline "waiting for jobs in #{queues.join(",")}"
      end
  end
end
