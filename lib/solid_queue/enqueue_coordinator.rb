# frozen_string_literal: true

require "singleton"

module SolidQueue
  # Group commit for fast-path enqueues on databases where durable commits
  # are expensive: concurrent enqueuers share one batched insert transaction,
  # each returning only after that durable commit lands. The first arrival
  # leads, collects for a window scaled to the measured commit cost, and
  # writes every collected job in one durable write; whoever accumulated
  # meanwhile is promoted to lead the next batch. A lone serial caller
  # skips the window, since nobody would join it. A failed batch is retried
  # entry by entry so each error reaches the caller that owns it.
  class EnqueueCoordinator
    include Singleton

    Entry = Data.define(:attributes, :scheduled, :waiter)

    class << self
      def enqueue(attributes, scheduled) = instance.enqueue(attributes, scheduled)
    end

    def initialize
      @mutex = Mutex.new
      @pending = nil
      @leading = false
      # Racy reads by design: any recently committed batch's duration is a
      # valid pace, so an atomic reference is all the synchronization needed
      @pace = Concurrent::AtomicReference.new(0.0)
      # The context that led the last batch alone with nobody behind it;
      # that same context leading again is a serial caller
      @solo_leader = Concurrent::AtomicReference.new(nil)
    end

    def enqueue(attributes, scheduled)
      # Per execution context, fiber-safe, and reused across enqueues; only
      # followers wait on it, but every entry carries one so entries stay
      # immutable data
      waiter = (ActiveSupport::IsolatedExecutionState[:solid_queue_enqueue_waiter] ||= Thread::Queue.new)
      entry = Entry.new(attributes:, scheduled:, waiter:)
      lead = false

      @mutex.synchronize do
        if @leading
          (@pending ||= []) << entry
        else
          @leading = true
          lead = true
        end
      end

      if lead
        collect_burst
        lead_entries(take_pending.unshift(entry))
      else
        result = entry.waiter.pop
        case result
        when Array # promoted: our entry is first
          collect_burst
          lead_entries(result.concat(take_pending))
        when Exception then raise result
        else result
        end
      end
    end

    private
      CHEAP_COMMIT = 0.002

      def take_pending
        @mutex.synchronize do
          taken = @pending || []
          @pending = nil
          taken
        end
      end

      # Every leader on an expensive commit, promoted or not, lets the burst
      # gather before writing: a promoted leader that wrote at once would
      # keep meeting the threads its predecessor released in the next batch,
      # splitting one burst into two commits forever
      def collect_burst
        pace = @pace.get
        return if pace < CHEAP_COMMIT
        # A serial caller is the same context leading solo batches back to
        # back; for it the window would be pure latency with nobody to
        # collect. Any other leader, or anyone already pending, waits.
        return if @pending.nil? && @solo_leader.get == ActiveSupport::IsolatedExecutionState.context

        window = pace / 2
        window = 0.01 if window > 0.01
        deadline = Concurrent.monotonic_time + window
        last_size = -1
        loop do
          sleep(0.001)
          size = @pending&.size || 0
          break if size == last_size
          last_size = size
          break if Concurrent.monotonic_time >= deadline
        end
      end

      # Writes the whole batch, records commit pace, hands leadership to any
      # batch that accumulated meanwhile, then distributes ids or retries
      # entries singly so failures attribute to their own callers. Returns
      # the leader's own id (its entry is always first).
      def lead_entries(entries)
        started = Concurrent.monotonic_time
        ids = nil
        error = nil
        begin
          ids = write_batch(entries)
        rescue Exception => e
          error = e
        end
        duration = Concurrent.monotonic_time - started
        previous = @pace.get
        @pace.set(previous.zero? ? duration : previous * 0.8 + duration * 0.2)

        next_entries = nil
        @mutex.synchronize do
          next_entries = @pending
          @pending = nil
          @leading = false if next_entries.nil?
        end
        @solo_leader.set(entries.size == 1 && next_entries.nil? ? ActiveSupport::IsolatedExecutionState.context : nil)
        next_entries.first.waiter.push(next_entries) if next_entries

        if error
          entries.each_with_index do |entry, i|
            next if i.zero?
            entry.waiter.push(single_result(entry))
          end
          own = single_result(entries.first)
          raise own if own.is_a?(Exception)
          own
        else
          entries.each_with_index do |entry, i|
            entry.waiter.push(ids[i]) unless i.zero?
          end
          ids.first
        end
      end

      def single_result(entry)
        write_batch([ entry ]).first
      rescue Exception => e
        e
      end

      # One durable write per batch on a briefly checked-out connection; the
      # adapter decides the statements, the coordinator only shapes rows
      def write_batch(entries)
        now = Time.current
        job_rows = entries.map do |entry|
          attributes = entry.attributes
          { queue_name: attributes["queue_name"], class_name: attributes["class_name"],
            arguments: attributes["arguments"], priority: attributes["priority"],
            active_job_id: attributes["active_job_id"], scheduled_at: entry.scheduled,
            created_at: now, updated_at: now }
        end

        Job.connection_pool.with_connection do
          adapter.serialize_writes { adapter.write_enqueue_batch(job_rows, now) }
        end
      end

      def adapter
        @adapter ||= DatabaseAdapter.resolve
      end
  end
end
