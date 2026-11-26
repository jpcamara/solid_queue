# frozen_string_literal: true

module SolidQueue
  module DatabaseAdapters
    class Postgresql
      module ScheduledDispatching
        # With SolidQueue.dispatch_cursors, a dispatcher remembers the position
        # (scheduled_at, priority, job_id) of the last scheduled job it
        # selected, and selects the next ones after it, in one seek of the
        # dispatch index, instead of reading due jobs from its start. Jobs
        # dispatched earlier leave their index entries behind until vacuum
        # removes them, which it can't while an older transaction is open, and
        # every poll from the start would read through them all again.
        #
        # A job can come in behind the position: one committed after the
        # dispatcher passed its place, one skipped while another dispatcher had
        # it locked and then left, or one whose scheduled_at, set by the
        # clock of the process that enqueued it, is behind the dispatcher's.
        # So every dispatch_cursors_full_pass_interval (less up to a quarter,
        # so dispatchers started together don't line up), and after any pass
        # from the start that fills its batch, the dispatcher reads from the
        # start, as without cursors. Such a job waits for that pass.
        #
        # Positions are kept per process and database, and start over in a
        # forked process. A pass that finds nothing keeps the position.
        def dispatch_scheduled(batch_size)
          return super unless SolidQueue.dispatch_cursors

          cursor = dispatch_cursor
          full_pass = cursor.full_pass_due?

          ScheduledExecution.dispatch_due(batch_size, after: (cursor.position unless full_pass)) do |selected, last|
            cursor.advance(last) if last
            cursor.full_pass_done if full_pass && selected < batch_size
          end
        end

        # Forgets every position, as a new process would
        def reset_dispatch_cursors!
          @dispatch_cursors = nil
        end

        # Makes the next pass of every dispatcher in this process read from the start
        def expire_dispatch_full_passes!
          @dispatch_cursors&.each_value(&:expire_full_pass)
        end

        private
          def dispatch_cursor
            if @dispatch_cursors_pid != ::Process.pid
              @dispatch_cursors_pid = ::Process.pid
              @dispatch_cursors = nil
            end

            (@dispatch_cursors ||= Concurrent::Map.new).compute_if_absent(ScheduledExecution.connection_pool) { DispatchCursor.new }
          end

          class DispatchCursor
            JITTER = 0.25

            def initialize
              @mutex = Mutex.new
              @position = nil
              @next_full_pass_at = nil
            end

            def position
              @mutex.synchronize { @position }
            end

            def full_pass_due?
              @mutex.synchronize { @next_full_pass_at.nil? || now >= @next_full_pass_at }
            end

            def advance(position)
              @mutex.synchronize { @position = position if @position.nil? || (position <=> @position) > 0 }
            end

            def expire_full_pass
              @mutex.synchronize { @next_full_pass_at = nil }
            end

            def full_pass_done
              interval = SolidQueue.dispatch_cursors_full_pass_interval
              @mutex.synchronize { @next_full_pass_at = now + interval - rand * JITTER * interval }
            end

            private
              def now
                ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
              end
          end
      end
    end
  end
end
