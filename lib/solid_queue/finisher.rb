# frozen_string_literal: true

module SolidQueue
  # Finishes the jobs a worker has performed successfully in groups. The
  # worker's threads hand their claimed executions over to a single thread,
  # which finishes whatever is waiting in one transaction, then takes the
  # next group: the busier the worker, the bigger the groups.
  #
  # A job keeps its claim until its group commits, so if the process dies
  # first, its claim is handled like any other claim of a dead process.
  class Finisher
    include AppExecutor

    def initialize(size)
      # Bounded so that threads can't keep running jobs while their claims
      # pile up unfinished: a thread waits here once the queue is full.
      @queue = Thread::SizedQueue.new(size)
    end

    def start
      @thread = create_thread { finish_in_groups }
    end

    def finish(execution)
      if thread&.alive?
        queue.push(execution)
      else
        finish_all [ execution ]
      end
    rescue ClosedQueueError
      # Stopping: finish it right away
      finish_all [ execution ]
    end

    # Finishes the executions still waiting before returning
    def stop(timeout)
      queue.close
      thread&.join(timeout)
    end

    private
      attr_reader :queue, :thread

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
        finish_all(executions)
      rescue Exception => error
        handle_thread_error(error)

        # Finish them one by one, so one execution can't keep the others
        # from finishing. Those finished already are skipped.
        executions.each do |execution|
          finish_all [ execution ]
        rescue Exception => error
          handle_thread_error(error)
        end
      end

      def finish_all(executions)
        wrap_in_app_executor { ClaimedExecution.finish_all(executions) }
      end
  end
end
