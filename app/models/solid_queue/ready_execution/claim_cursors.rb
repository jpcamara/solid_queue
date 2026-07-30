# frozen_string_literal: true

module SolidQueue
  class ReadyExecution
    # Process-local claim cursors: for each queue key, the last (priority, id)
    # position this process observed. Cursor-guided queries can descend the
    # polling index past dead tuples instead of scanning them.
    #
    # A cursor is not a lower bound for live work. A competing claim below it
    # can roll back (its own transaction or an enclosing one), a row can
    # receive a lower sequence id but commit after the cursor advances, and an
    # empty SKIP LOCKED seek can mean the remaining rows were locked elsewhere
    # rather than gone. The periodic cursor-free discovery query is therefore
    # fundamental to finding work, not merely defensive healing.
    class ClaimCursors
      def initialize(clock: -> { ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) })
        @clock = clock
        @mutex = Mutex.new
        @positions = {}
        @next_discovery_at = {}
      end

      def state(key)
        @mutex.synchronize { [ discovery_due_without_lock?(key), @positions[key]&.dup ] }
      end

      def position(key)
        @mutex.synchronize { @positions[key]&.dup }
      end

      def advance(key, position)
        @mutex.synchronize do
          current = @positions[key]
          @positions[key] = position.dup if current.nil? || (current <=> position).negative?
        end
      end

      def clear(key, expected_position)
        @mutex.synchronize do
          @positions.delete(key) if @positions[key] == expected_position
        end
      end

      def discovery_due?(key)
        @mutex.synchronize { discovery_due_without_lock?(key) }
      end

      def record_discovery(key, position)
        @mutex.synchronize do
          @positions[key] = position&.dup
          @next_discovery_at[key] = monotonic_time + SolidQueue.claim_cursors_discovery_interval
        end
      end

      def expire_discovery!(key)
        @mutex.synchronize { @next_discovery_at[key] = monotonic_time }
      end

      def reset!
        @mutex.synchronize do
          @positions.clear
          @next_discovery_at.clear
        end
      end

      private
        def discovery_due_without_lock?(key)
          deadline = @next_discovery_at[key]
          deadline.nil? || monotonic_time >= deadline
        end

        def monotonic_time
          @clock.call
        end
    end
  end
end
