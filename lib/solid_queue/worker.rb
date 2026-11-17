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
      attr_reader :prefetched, :prefetched_mutex

      def poll
        return 10.minutes if claiming_ahead? && prefetched_enough?

        limit = claim_limit
        claim_executions(limit).then do |executions|
          # Keep claiming ahead while claims come back full, as the queues are deep
          @claiming_ahead = prefetch > 0 && executions.any? && executions.size == limit

          prefetched_mutex.synchronize { prefetched.concat(executions) }
          post_prefetched

          if claiming_ahead? then 0
          elsif pool.idle? then polling_interval
          else 10.minutes
          end
        end
      end

      def claim_limit
        if claiming_ahead?
          pool.available_capacity + prefetch - prefetched.size
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

      def prefetched_enough?
        prefetched.size > prefetch / 2
      end

      def post_prefetched
        prefetched_mutex.synchronize do
          pool.post(prefetched.shift) while prefetched.any? && pool.idle?
          prefetched.size
        end
      end

      # Runs in the pool when a thread or fiber becomes free: it hands it the next
      # prefetched job, if any, and wakes the worker to claim more when needed
      def post_prefetched_on_idle
        remaining = post_prefetched unless stopped? || pool.shutdown?
      ensure
        wake_up unless remaining && remaining > prefetch / 2
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
