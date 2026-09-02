# frozen_string_literal: true

module SolidQueue
  # Group commit for fast-path enqueues on databases where durable commits
  # are expensive: concurrent enqueuers share one batched insert transaction,
  # each returning only after that durable commit lands. The first arrival
  # leads, collects for a window scaled to the measured commit cost, and
  # writes every collected job in a single round trip. A failed batch is
  # retried entry by entry so each error reaches the caller that owns it.
  class EnqueueCoordinator
    Entry = Struct.new(:attributes, :scheduled, :waiter)

    class << self
      def instance
        @instance ||= new
      end

      def enqueue(attributes, scheduled) = instance.enqueue(attributes, scheduled)
    end

    def initialize
      @mutex = Mutex.new
      @pending = nil
      @leading = false
      @pace = 0.0
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
        pace = @pace
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
        @pace = @pace.zero? ? duration : @pace * 0.8 + duration * 0.2

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

      # One multi-statement round trip: a single multi-row insert is a
      # "simple insert", so InnoDB allocates its auto-increment ids
      # consecutively in every autoinc lock mode and LAST_INSERT_ID returns
      # the first id of the batch.
      def write_batch(entries)
        with_client do |client|
          write_batch_on(client, entries)
        end
      end

      # Only one leader writes at a time (plus a promotion in flight), so a
      # small borrowed pool serves any number of enqueuing threads without
      # holding a connection per thread
      def with_client
        client = nil
        @mutex.synchronize do
          @clients ||= []
          @client_count ||= 0
          client = @clients.pop
          if client.nil? && @client_count < 4
            @client_count += 1
            config = Job.connection_pool.db_config.configuration_hash
            client = Mysql2::Client.new(config.merge(flags: Mysql2::Client::MULTI_STATEMENTS))
          end
        end
        client ||= begin
          sleep 0.001 until (client = @mutex.synchronize { @clients.pop })
          client
        end
        begin
          yield client
        ensure
          @mutex.synchronize { @clients.push(client) }
        end
      end

      def write_batch_on(client, entries)
        now = Job.fast_enqueue_timestamp(Time.now)

        job_rows = entries.map do |entry|
          a = entry.attributes
          scheduled = entry.scheduled ? "'#{client.escape(entry.scheduled)}'" : "NULL"
          "('#{client.escape(a["queue_name"])}', '#{client.escape(a["class_name"])}', '#{client.escape(a["arguments"])}', " \
            "#{a["priority"].to_i}, '#{client.escape(a["active_job_id"])}', #{scheduled}, '#{now}', '#{now}')"
        end.join(",")

        ready_rows = entries.each_index.map do |i|
          a = entries[i].attributes
          "(@sq_first + #{i}, '#{client.escape(a["queue_name"])}', #{a["priority"].to_i}, '#{now}')"
        end.join(",")

        result = client.query(<<~SQL)
          BEGIN;
          INSERT INTO solid_queue_jobs (queue_name, class_name, arguments, priority, active_job_id, scheduled_at, created_at, updated_at)
          VALUES #{job_rows};
          SET @sq_first = LAST_INSERT_ID();
          INSERT INTO solid_queue_ready_executions (job_id, queue_name, priority, created_at)
          VALUES #{ready_rows};
          COMMIT;
          SELECT @sq_first
        SQL
        while client.next_result
          r = client.store_result
          result = r if r
        end
        first_id = result.first.values.first.to_i
        entries.each_index.map { |i| first_id + i }
      rescue Mysql2::Error => e
        begin client.query("ROLLBACK"); rescue Mysql2::Error; end
        raise Job::EnqueueError.new("#{e.class.name}: #{e.message}").tap { |err| err.set_backtrace(e.backtrace) }
      end
  end
end
