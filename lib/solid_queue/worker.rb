# frozen_string_literal: true

module SolidQueue
  class Worker < Processes::Poller
    include LifecycleHooks

    after_boot :run_start_hooks
    before_shutdown :run_stop_hooks
    after_shutdown :run_exit_hooks

    attr_reader :queues, :pool

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

      super(**options)
    end

    def metadata
      super.merge(queues: queues.join(","), pool_type: pool.type, pool_size: pool.size)
    end

    private
      # Claim more than the pool can run at once: claimed rows are this
      # worker's either way (crash recovery releases them), and deeper claim
      # batches amortize the claim transaction across more jobs
      PREFETCH_FACTOR = 50

      def poll
        @backlog ||= []
        @backlog.concat(claim_executions) if @backlog.empty?

        while pool.available_capacity > 0 && (execution = @backlog.shift)
          pool.post(execution)
        end

        # Nothing claimed and nothing running: don't sit on buffered completions
        SolidQueue::CompletionBuffer.flush if @backlog.empty? && pool.idle?

        pool.idle? ? polling_interval : 10.minutes
      end

      def claim_executions
        with_polling_volume do
          SolidQueue::ReadyExecution.claim(queues, pool.size * PREFETCH_FACTOR, process_id).tap do |executions|
            # Load jobs in one query, outside the claim transaction so the
            # locked section stays as short as possible
            ActiveRecord::Associations::Preloader.new(records: executions, associations: :job).call if executions.any?
          end
        end
      end

      def shutdown
        pool.shutdown
        pool.wait_for_termination(SolidQueue.shutdown_timeout)
        # Flush buffered completions after the pool stops adding to them and
        # before deregistration releases this worker's remaining claims
        wrap_in_app_executor { SolidQueue::CompletionBuffer.flush }

        super
      end

      def all_work_completed?
        (@backlog.nil? || @backlog.empty?) && SolidQueue::ReadyExecution.aggregated_count_across(queues).zero?
      end

      def set_procline
        procline "waiting for jobs in #{queues.join(",")}"
      end
  end
end
