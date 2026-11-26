# frozen_string_literal: true

module SolidQueue
  module DatabaseAdapters
    class Postgresql
      # Claims along a cursor, with SolidQueue.claim_cursors set: for each
      # queue, the process remembers the (priority, id) position of the last
      # ready execution it claimed, and seeks past it in the index instead of
      # reading from the start. Claimed and deleted ready executions leave dead
      # index entries at the start, which vacuum can't remove while an older
      # transaction is open, on the primary or, with hot_standby_feedback, on a
      # replica, and a claim from the start reads through all of them.
      #
      # A position isn't a lower bound for work: a claim below it can roll
      # back, a row can get a lower id but commit after the position passed
      # it, and a seek that skips rows locked by others can come back empty
      # while they're still there. Discovery passes that don't use the
      # position find those:
      #
      # * A floored pass, every claim_cursors_discovery_interval (1 second):
      #   it reads up to FLOORED_WINDOW ready executions above the floor, in id
      #   order, picks in (priority, id) order in memory, and claims the picks
      #   by id, with no ORDER BY, so no plan walks the index from its start.
      #   The floor is the highest id the process had seen before its last
      #   full pass, which every row allocated since is above. Then it seeks
      #   above the position for the rest of the limit.
      # * A full pass, every claim_cursors_full_discovery_interval (10
      #   seconds, jittered earlier so processes started together don't run it
      #   at once): a claim from the start, as without cursors. The only pass
      #   that reaches rows below the floor, so the only one that moves the
      #   position anywhere.
      #
      # Within a priority, claims follow the order executions became ready
      # (id) instead of the order jobs were enqueued (job_id). The indexes the
      # solid_queue:claim_cursors generator's migration adds serve the seeks.
      # Each claim is the one statement Claiming runs, with other candidates.
      module ClaimCursors
        FLOORED_WINDOW = 500

        # A queue's position, floor and discovery deadlines, kept by the
        # process for each queue key.
        class Cursors
          # Deadlines land up to this fraction before the interval, so
          # processes started together don't run their full passes at once,
          # and the interval stays the longest a row waits for one
          FULL_DISCOVERY_JITTER = 0.25

          def initialize(clock: -> { ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) })
            @clock = clock
            @mutex = Mutex.new
            @positions = {}
            @floors = {}
            @observed_max_id = nil
            @next_discovery_at = {}
            @next_full_discovery_at = {}
          end

          # The highest ready execution id the process has seen on any queue.
          # Ids are allocated in increasing order, so rows allocated later
          # are above it; anything that breaks that (sequence caching,
          # setval) only delays a row until the next full pass, like a late
          # commit.
          def observe(id)
            @mutex.synchronize do
              @observed_max_id = id if id && (@observed_max_id.nil? || id > @observed_max_id)
            end
          end

          def observed_max_id
            @mutex.synchronize { @observed_max_id }
          end

          def state(key)
            @mutex.synchronize { [ discovery_without_lock(key), @floors[key], @positions[key]&.dup ] }
          end

          def position(key)
            @mutex.synchronize { @positions[key]&.dup }
          end

          def floor(key)
            @mutex.synchronize { @floors[key] }
          end

          def advance(key, position)
            @mutex.synchronize do
              current = @positions[key]
              @positions[key] = position.dup if current.nil? || (current <=> position).negative?
            end
          end

          def discovery_due?(key)
            @mutex.synchronize { due_without_lock?(@next_discovery_at, key) }
          end

          def full_discovery_due?(key)
            @mutex.synchronize { due_without_lock?(@next_full_discovery_at, key) }
          end

          def record_full_discovery(key, position, floor)
            @mutex.synchronize do
              @positions[key] = position&.dup
              @floors[key] = floor
              @next_discovery_at[key] = monotonic_time + SolidQueue.claim_cursors_discovery_interval
              @next_full_discovery_at[key] = monotonic_time + jittered_full_discovery_interval
            end
          end

          # A floored pass sees only the part of the index above its floor, so
          # it may set a missing position but never move one: rows its floor
          # hid would end up below the position, out of reach of everything
          # but the next full pass.
          def seed(key, position)
            @mutex.synchronize do
              @positions[key] = position.dup if @positions[key].nil?
            end
          end

          def record_floored_discovery(key)
            @mutex.synchronize do
              @next_discovery_at[key] = monotonic_time + SolidQueue.claim_cursors_discovery_interval
            end
          end

          def expire_discovery!(key)
            @mutex.synchronize { @next_discovery_at[key] = monotonic_time }
          end

          def expire_full_discovery!(key)
            @mutex.synchronize do
              @next_discovery_at[key] = monotonic_time
              @next_full_discovery_at[key] = monotonic_time
            end
          end

          def reset!
            @mutex.synchronize do
              @positions.clear
              @floors.clear
              @observed_max_id = nil
              @next_discovery_at.clear
              @next_full_discovery_at.clear
            end
          end

          private
            def discovery_without_lock(key)
              return nil unless due_without_lock?(@next_discovery_at, key)
              return :full if @floors[key].nil? || due_without_lock?(@next_full_discovery_at, key)

              :floored
            end

            def due_without_lock?(deadlines, key)
              deadline = deadlines[key]
              deadline.nil? || monotonic_time >= deadline
            end

            def jittered_full_discovery_interval
              interval = SolidQueue.claim_cursors_full_discovery_interval
              interval - rand * FULL_DISCOVERY_JITTER * interval
            end

            def monotonic_time
              @clock.call
            end
        end

        class << self
          # Positions, floors and deadlines are positions in one table's id
          # space, so there's a set per connection pool, which stands for the
          # database. Forked processes start their own.
          def for(pool)
            registry.compute_if_absent(pool) { Cursors.new }
          end

          def reset!
            registry.each_value(&:reset!)
          end

          private
            def registry
              if @pid != ::Process.pid
                @pid = ::Process.pid
                @registry = Concurrent::Map.new
              end

              @registry
            end
        end

        def claim(queue_list, process_id, limit)
          return super unless SolidQueue.claim_cursors

          ReadyExecution.with_connection do |connection|
            return super if connection.preventing_writes?

            ReadyExecution.claim_from_each_queue(queue_list, limit) do |queue_relation, remaining, key|
              claim_with_cursor(connection, key, queue_relation, process_id, remaining).tap do |claimed|
                instrument_claim(process_id, claimed)
              end
            end
          end
        end

        # The cursors of the database ready executions are in
        def claim_cursors
          ClaimCursors.for(ReadyExecution.connection_pool)
        end

        private
          def claim_with_cursor(connection, key, queue_relation, process_id, limit)
            discovery, floor, position = claim_cursors.state(key)

            case discovery
            when :full    then claim_discovering(connection, key, queue_relation, process_id, limit)
            when :floored then claim_discovering_above(connection, key, floor, position, queue_relation, process_id, limit)
            else
              position ? claim_along_cursor(connection, key, position, queue_relation, process_id, limit) : []
            end
          end

          # A claim from the start, in (priority, id) order. Its floor is the
          # highest id seen before it, so every row that arrives after is above.
          def claim_discovering(connection, key, queue_relation, process_id, limit)
            floor = claim_cursors.observed_max_id
            claimed, positions = claim_positioned(connection, queue_relation.order(:priority, :id).limit(limit), process_id)

            claim_cursors.observe(positions.map(&:last).max)
            claim_cursors.record_full_discovery(key, positions.last, floor)

            claimed
          end

          # The window is read, not claimed: the floor follows what's claimed
          # only, or it would rise over rows that were merely outside the pick,
          # leaving them for the full pass. One transaction for both claims, so
          # a failure in the seek doesn't leave the picks claimed by no one. The
          # next floored pass is due again only once the region below the
          # position is drained, or rows there would wait behind lower-priority
          # work above it.
          def claim_discovering_above(connection, key, floor, position, queue_relation, process_id, limit)
            drained = seed = nil

            claimed = ReadyExecution.transaction(requires_new: true) do
              window = queue_relation.where("id > ?", floor).order(:id).limit(FLOORED_WINDOW).select(:id, :priority).to_a
              region = position ? window.select { |row| ([ row.priority, row.id ] <=> position) <= 0 } : window
              picked = region.map { |row| [ row.priority, row.id ] }.sort.first(limit)

              below = picked.any? ? claim_positioned(connection, queue_relation.where("id = ANY(CAST($2 AS bigint[]))"), process_id, [ "{#{picked.map(&:last).join(",")}}" ]).first : []
              drained = window.size < FLOORED_WINDOW && picked.size < limit
              seed = picked.last unless position

              if position && below.size < limit
                below + claim_along_cursor(connection, key, position, queue_relation, process_id, limit - below.size)
              else
                below
              end
            end

            claim_cursors.seed(key, seed) if seed
            claim_cursors.record_floored_discovery(key) if drained

            claimed
          end

          # One seek in the index across every priority. An empty seek keeps
          # the position: new rows get higher ids, so the next one finds them.
          def claim_along_cursor(connection, key, position, queue_relation, process_id, limit)
            relation = queue_relation.where("(priority, id) > (CAST($2 AS integer), CAST($3 AS bigint))").order(:priority, :id).limit(limit)
            claimed, positions = claim_positioned(connection, relation, process_id, position)

            if positions.any?
              claim_cursors.observe(positions.map(&:last).max)
              claim_cursors.advance(key, positions.last)
            end

            claimed
          end

          # Claims the relation's ready executions in one statement, as Claiming
          # does, binding values after the process id as $2 and on. Returns the
          # claims, in (priority, id) order, and their positions.
          def claim_positioned(connection, relation, process_id, values = [])
            candidates = relation.non_blocking_lock.select(:id, :job_id, :priority).to_sql
            rows = run_claim(connection, "WITH candidates AS (#{candidates}), #{positioned_claim_sql}", [ process_id, *values ])
              .sort_by { |row| [ row["ready_priority"], row["ready_id"] ] }

            positions = rows.map { |row| [ row.delete("ready_priority"), row.delete("ready_id") ] }
            [ rows.map { |row| claim_from(row) }, positions ]
          end

          def positioned_claim_sql
            @positioned_claim_sql ||= begin
              ready, claims, jobs = ReadyExecution.quoted_table_name, ClaimedExecution.quoted_table_name, Job.quoted_table_name

              <<~SQL.squish.freeze
                claimed AS (
                  INSERT INTO #{claims} (job_id, process_id, created_at)
                  SELECT job_id, CAST($1 AS bigint), CURRENT_TIMESTAMP FROM candidates
                  RETURNING id, job_id, process_id, created_at
                ), deleted AS (
                  DELETE FROM #{ready} USING candidates WHERE #{ready}.id = candidates.id
                )
                SELECT #{jobs}.*, claimed.id AS claimed_id, claimed.process_id AS claimed_process_id,
                  claimed.created_at AS claimed_created_at, candidates.id AS ready_id, candidates.priority AS ready_priority
                FROM claimed JOIN #{jobs} ON #{jobs}.id = claimed.job_id JOIN candidates ON candidates.job_id = claimed.job_id
              SQL
            end
          end
      end
    end
  end
end
