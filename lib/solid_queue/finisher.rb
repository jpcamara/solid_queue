# frozen_string_literal: true

module SolidQueue
  # Finishes the jobs a worker has run successfully, in groups. The worker's
  # threads hand each claimed execution over and go on to their next job, and
  # this thread finishes all the executions waiting in one transaction. The
  # busier the worker, the bigger the groups, up to its pool size. If a group
  # fails, each of its executions is finished on its own, as without a
  # finisher. Concurrency-limited jobs aren't handed over: their threads
  # finish them and give their slots to the next jobs at once.
  #
  # A job keeps its claim until its group commits. Stopping the worker
  # finishes the executions waiting before it deregisters. If the process
  # dies first, their claims are handled like those of the jobs it was
  # running.
  class Finisher
    include AppExecutor

    def initialize(size, on_unrecoverable_error: nil)
      # Bounded, so threads wait here rather than run more jobs once as many
      # executions as the pool has threads are waiting to be finished
      @queue = Thread::SizedQueue.new(size)
      @on_unrecoverable_error = on_unrecoverable_error
    end

    def start
      @thread = create_thread { finish_in_groups }
    end

    def finish(execution)
      queue.push(execution)
    rescue ClosedQueueError
      finish_alone(execution)
    end

    # Finishes the executions waiting before returning
    def stop(timeout)
      queue.close
      thread&.join(timeout)
    end

    private
      attr_reader :queue, :thread, :on_unrecoverable_error

      def name
        "solid_queue-finisher-#{object_id}"
      end

      def finish_in_groups
        while execution = queue.pop
          executions = [ execution ]
          executions << queue.pop until queue.empty?

          finish_group(executions)
        end
      end

      def finish_group(executions)
        finished = wrap_in_app_executor { finish_together(executions) }
        executions.each { |execution| finish_alone(execution) } unless finished
      end

      # Returns whether it could
      def finish_together(executions)
        # One execution is finished as it would be alone, which may not need a transaction
        if executions.one? then adapter.finish(executions.first)
        else ClaimedExecution.transaction { executions.each { |execution| adapter.finish(execution) } }
        end
        true
      rescue
        false
      end

      def adapter
        ClaimedExecution.database_adapter
      end

      # As a worker's thread does without a finisher
      def finish_alone(execution)
        wrap_in_app_executor { execution.finish }
      rescue Exception => error
        handle_thread_error(error)
        on_unrecoverable_error&.call if error.is_a?(Processes::UnrecoverableError)
      end
  end
end
