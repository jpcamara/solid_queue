# frozen_string_literal: true

module SolidQueue
  class Worker < Processes::Poller
    include LifecycleHooks

    after_boot :start_finisher, :run_start_hooks
    before_shutdown :run_stop_hooks
    after_shutdown :run_exit_hooks

    attr_reader :queues, :pool, :finisher

    def initialize(**options)
      execution_pool_type = options.key?(:fibers) ? :fiber : :thread

      options = options.dup.with_defaults(SolidQueue::Configuration::WORKER_DEFAULTS)
      execution_pool_size = execution_pool_type == :fiber ? options[:fibers] : options[:threads]

      # Ensure that the queues array is deep frozen to prevent accidental modification
      @queues = Array(options[:queues]).map(&:freeze).freeze

      @pool = Pool.build \
        type: execution_pool_type,
        size: execution_pool_size,
        on_idle: -> { wake_up }

      @finisher = Finisher.new(execution_pool_size)

      super(**options)
    end

    def metadata
      super.merge(queues: queues.join(","), pool_type: pool.type, pool_size: pool.size)
    end

    private
      def poll
        claim_executions.then do |executions|
          executions.each do |execution|
            execution.finisher = finisher
            pool.post(execution)
          end

          pool.idle? ? polling_interval : 10.minutes
        end
      end

      def claim_executions
        with_polling_volume do
          SolidQueue::ReadyExecution.claim(queues, pool.available_capacity, process_id)
        end
      end

      def shutdown
        pool.shutdown
        pool.wait_for_termination(SolidQueue.shutdown_timeout)
        # Before deregistering, which releases the claims left
        finisher.stop(SolidQueue.shutdown_timeout)

        super
      end

      def start_finisher
        finisher.start
      end

      def all_work_completed?
        SolidQueue::ReadyExecution.aggregated_count_across(queues).zero?
      end

      def set_procline
        procline "waiting for jobs in #{queues.join(",")}"
      end
  end
end
