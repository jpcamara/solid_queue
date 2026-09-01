# frozen_string_literal: true

module SolidQueue
  class Pool
    include AppExecutor

    def self.build(type:, size:, on_idle: nil)
      SolidQueue.const_get("#{type.to_s.camelize}Pool").new(size, on_idle: on_idle)
    end

    attr_reader :size

    def initialize(size, on_idle: nil)
      @size = size
      @on_idle = on_idle
      # Admit up to a queue's worth beyond running threads so pool threads
      # pull queued work immediately instead of waiting on a poller wake
      @available_capacity = size * 2
      @mutex = Mutex.new
    end

    def type
      self.class.name.demodulize.delete_suffix("Pool").underscore.to_sym
    end

    def post(execution)
      reserve_capacity!

      begin
        schedule(execution)
      rescue Exception
        restore_capacity
        raise
      end
    end

    def available_capacity
      mutex.synchronize { @available_capacity }
    end

    def idle?
      available_capacity.positive?
    end

    private
      attr_reader :mutex, :on_idle

      def schedule(execution)
        raise NotImplementedError
      end

      def perform_execution(execution)
        wrap_in_app_executor { execution.perform }
      rescue Exception => error
        handle_thread_error(error)
      ensure
        restore_capacity
      end

      def reserve_capacity!
        mutex.synchronize do
          raise RuntimeError, "Execution pool is at capacity" if @available_capacity <= 0

          @available_capacity -= 1
        end
      end

      def restore_capacity
        should_notify = mutex.synchronize do
          @available_capacity += 1
          # Wake the poller in batches, not per completion: refilling half the
          # admission window at a time keeps threads fed with far fewer wakes
          @available_capacity >= size
        end

        on_idle&.call if should_notify
      end
  end
end
