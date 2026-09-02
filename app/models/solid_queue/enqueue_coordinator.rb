# frozen_string_literal: true

require "singleton"

module SolidQueue
  # Group commit for fast-path enqueues on databases where durable commits
  # are expensive: concurrent enqueuers share one batched insert transaction,
  # each returning only after that durable commit lands. The first arrival
  # leads, collects for a window scaled to the measured commit cost, and
  # writes every collected job in a single round trip. A failed batch is
  # retried entry by entry so each error reaches the caller that owns it.
  class EnqueueCoordinator
    include Singleton

    Entry = Struct.new(:attributes, :scheduled, :waiter)

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
    end

    def enqueue(attributes, scheduled)
      entry = Entry.new(attributes, scheduled, nil)
      lead = false

      @mutex.synchronize do
        if @leading
          entry.waiter = (Thread.current[:sq_enqueue_waiter] ||= Thread::Queue.new)
          (@pending ||= []) << entry
        else
          @leading = true
          lead = true
        end
      end

      if lead
        collect_burst
        entries = nil
        @mutex.synchronize do
          entries = @pending || []
          @pending = nil
        end
        entries.unshift(entry)
        lead_entries(entries)
      else
        result = entry.waiter.pop
        case result
        when Array then lead_entries(result) # promoted: our entry is first
        when Exception then raise result
        else result
        end
      end
    end

    private
      CHEAP_COMMIT = 0.002

      def collect_burst
        pace = @pace.get
        return if pace < CHEAP_COMMIT

        window = pace / 2
        window = 0.01 if window > 0.01
        deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + window
        last_size = -1
        loop do
          sleep(0.001)
          size = @pending&.size || 0
          break if size == last_size
          last_size = size
          break if ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) >= deadline
        end
      end

      # Writes the whole batch, records commit pace, hands leadership to any
      # batch that accumulated meanwhile, then distributes ids or retries
      # entries singly so failures attribute to their own callers. Returns
      # the leader's own id (its entry is always first).
      def lead_entries(entries)
        started = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
        ids = nil
        error = nil
        begin
          ids = write_batch(entries)
        rescue Exception => e
          error = e
        end
        duration = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started
        previous = @pace.get
        @pace.set(previous.zero? ? duration : previous * 0.8 + duration * 0.2)

        next_entries = nil
        @mutex.synchronize do
          next_entries = @pending
          @pending = nil
          @leading = false if next_entries.nil?
        end
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

      # One transaction per batch, written with Active Record's bulk API on
      # a briefly checked-out connection. A single multi-row insert receives
      # consecutive auto-increment ids on MySQL (simple inserts allocate in
      # one chunk in every autoinc lock mode) and consecutive rowids on
      # SQLite (single writer), so the whole batch's ids follow from one
      # value; PostgreSQL simply returns them.
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
          adapter.serialize_writes { insert_batch(entries, job_rows, now) }
        end
      end

      def adapter
        @adapter ||= DatabaseAdapter.resolve
      end

      def insert_batch(entries, job_rows, now)
        Job.transaction do
          ids = adapter.insert_jobs_returning_ids(job_rows)
          ReadyExecution.insert_all!(entries.each_index.map { |i|
            { job_id: ids[i], queue_name: job_rows[i][:queue_name],
              priority: job_rows[i][:priority], created_at: now }
          })
          ids
        end
      end
  end
end
