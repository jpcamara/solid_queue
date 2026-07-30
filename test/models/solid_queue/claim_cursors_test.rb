require "test_helper"

class SolidQueue::ClaimCursorsTest < ActiveSupport::TestCase
  PROCESS_ID = 42

  setup do
    skip "Claim cursors require PostgreSQL" unless SolidQueue::Record.connection_db_config.adapter.match?(/postg/i)
    SolidQueue::ReadyExecution.claim_cursors.reset!
    # The dummy app shortens the interval for integration latency; these tests
    # control discovery explicitly via expire_discovery!
    @original_discovery_interval = SolidQueue.claim_cursors_discovery_interval
    @original_full_discovery_interval = SolidQueue.claim_cursors_full_discovery_interval
    SolidQueue.claim_cursors_discovery_interval = 10.minutes
    SolidQueue.claim_cursors_full_discovery_interval = 10.minutes
  end

  teardown do
    SolidQueue::ReadyExecution.claim_cursors.reset!
    SolidQueue.claim_cursors = true
    SolidQueue.claim_cursors_discovery_interval = @original_discovery_interval if @original_discovery_interval
    SolidQueue.claim_cursors_full_discovery_interval = @original_full_discovery_interval if @original_full_discovery_interval
  end

  test "advance is monotonic per key" do
    cursors.advance("*", [ 0, 10 ])
    cursors.advance("*", [ 0, 5 ])
    assert_equal [ 0, 10 ], cursors.position("*")

    cursors.advance("*", [ 1, 1 ])
    assert_equal [ 1, 1 ], cursors.position("*")
  end

  test "clear only removes the position it observed" do
    cursors.advance("*", [ 0, 10 ])

    cursors.clear("*", [ 0, 5 ]) # stale observation from a slower thread
    assert_equal [ 0, 10 ], cursors.position("*")

    cursors.clear("*", [ 0, 10 ])
    assert_nil cursors.position("*")
  end

  test "cursors are tracked independently per queue" do
    AddToBufferJob.set(queue: :first).perform_later("a")
    AddToBufferJob.set(queue: :second).perform_later("b")

    claim(1, queues: "first")
    first_position = cursors.position("first")
    assert_not_nil first_position
    assert_nil cursors.position("second")
    assert_equal 1, SolidQueue::ReadyExecution.count

    claim(1, queues: "second")
    assert_not_nil cursors.position("second")
    assert_equal first_position, cursors.position("first")
  end

  test "an empty discovery suppresses claim queries until the next one is due" do
    assert_empty claim(1) # discovery against an empty queue records a nil position

    queries = capture_candidate_queries do
      3.times { assert_empty claim(1) }
    end
    assert_empty queries
  end

  test "discovery seeds a single lexicographic position" do
    2.times { |i| AddToBufferJob.perform_later(i) }
    executions = SolidQueue::ReadyExecution.ordered.to_a

    assert_equal 1, claim(1).size
    assert_equal position_of(executions.first), cursors.position("*")

    assert_equal 1, claim(1).size
    assert_equal position_of(executions.second), cursors.position("*")
  end

  test "fast path claims across priorities with one cursor query" do
    AddToBufferJob.set(priority: 1).perform_later("seed")
    claim(1)

    AddToBufferJob.set(priority: 1).perform_later("high")
    AddToBufferJob.set(priority: 5).perform_later("low")

    queries = capture_candidate_queries do
      claimed_jobs = claim(2).sort_by(&:id).map { |execution| SolidQueue::Job.find(execution.job_id) }
      assert_equal [ 1, 5 ], claimed_jobs.map(&:priority)
    end

    assert_equal 1, queries.size
    assert_includes queries.sole, "(priority, id) > ("
  end

  test "fast path immediately finds new work at the current priority" do
    AddToBufferJob.set(priority: 3).perform_later("seed")
    claim(1)

    AddToBufferJob.set(priority: 3).perform_later("next")

    assert_equal 1, claim(1).size
    assert_equal 0, SolidQueue::ReadyExecution.count
  end

  test "empty seek clears the position and skips cursor queries until discovery is due" do
    AddToBufferJob.perform_later("seed")
    claim(1)

    queries = capture_candidate_queries { assert_empty claim(1) }
    assert_equal 1, queries.size
    assert_nil cursors.position("*")
    assert_not cursors.discovery_due?("*")

    queries = capture_candidate_queries do
      3.times { assert_empty claim(1) }
    end
    assert_empty queries
  end

  test "higher priority arrivals are picked up once discovery is due" do
    AddToBufferJob.set(priority: 5).perform_later("seed")
    claim(1)

    AddToBufferJob.set(priority: 1).perform_later("higher")

    assert_empty claim(1)
    assert_nil cursors.position("*")

    cursors.expire_discovery!("*")
    claimed = claim(1)

    assert_equal 1, claimed.size
    assert_equal 1, SolidQueue::Job.find(claimed.sole.job_id).priority
  end

  test "discovery heals an overshot position" do
    AddToBufferJob.perform_later("seed")
    claim(1)

    AddToBufferJob.perform_later("stranded")
    execution = SolidQueue::ReadyExecution.sole
    cursors.advance("*", [ execution.priority, execution.id + 1000 ])

    assert_empty claim(1)
    assert_nil cursors.position("*")

    cursors.expire_discovery!("*")
    claimed = claim(1)

    assert_equal 1, claimed.size
    assert_equal "stranded", SolidQueue::Job.find(claimed.sole.job_id).arguments.dig("arguments").first
  end

  test "within a priority, claims follow readiness order, not enqueue order" do
    scheduled = AddToBufferJob.set(wait: 5.minutes).perform_later("scheduled first")
    immediate = AddToBufferJob.perform_later("enqueued second")

    travel_to(6.minutes.from_now) { SolidQueue::ScheduledExecution.dispatch_next_batch(10) }

    claimed_jobs = claim(2).sort_by(&:id).map { |execution| SolidQueue::Job.find(execution.job_id) }
    assert_equal [ immediate.job_id, scheduled.job_id ], claimed_jobs.map(&:active_job_id)
  end

  test "discovery is unbounded until a pass has recorded a watermark" do
    AddToBufferJob.perform_later("seed")

    queries = capture_candidate_queries { assert_equal 1, claim(1).size }

    assert_equal 1, queries.size
    assert_not_includes queries.sole, "id > "
    assert_not_nil cursors.floor("*")
  end

  test "a floored pass sweeps below the cursor and seeks above it in one poll" do
    AddToBufferJob.perform_later("seed")
    claim(1)

    AddToBufferJob.perform_later("next")
    cursors.expire_discovery!("*")

    queries = capture_candidate_queries { assert_equal 1, claim(1).size }

    assert_equal 2, queries.size
    assert_includes queries.first, "(priority, id) <= ("
    assert_includes queries.first, "id > "
    assert_includes queries.second, "(priority, id) > ("
  end

  test "a floored pass finds a higher priority arrival without scanning below the watermark" do
    AddToBufferJob.set(priority: 5).perform_later("seed")
    claim(1)
    position = cursors.position("*")

    AddToBufferJob.set(priority: 1).perform_later("higher")
    cursors.expire_discovery!("*")

    queries = capture_candidate_queries do
      claimed = claim(1)
      assert_equal 1, SolidQueue::Job.find(claimed.sole.job_id).priority
    end

    assert_equal 1, queries.size
    assert_includes queries.sole, "id > "
    # A pass that only sees part of the index must not move the cursor: the rows
    # its floor hid would fall below it and out of every other query
    assert_equal position, cursors.position("*")
  end

  test "successive floored passes reach every arrival below the cursor" do
    AddToBufferJob.set(priority: 9).perform_later("seed")
    claim(1)

    # The higher priority arrival takes the higher id, so a watermark that
    # followed the claims would jump over the one left behind
    lower = AddToBufferJob.set(priority: 5).perform_later("lower priority, lower id")
    higher = AddToBufferJob.set(priority: 1).perform_later("higher priority, higher id")

    cursors.expire_discovery!("*")
    assert_equal higher.job_id, claimed_active_job_ids(1).sole

    cursors.expire_discovery!("*")
    assert_equal lower.job_id, claimed_active_job_ids(1).sole
  end

  test "a floored pass with no cursor spans every priority and seeds one" do
    AddToBufferJob.set(priority: 5).perform_later("seed")
    claim(1)
    assert_empty claim(1)
    assert_nil cursors.position("*")

    AddToBufferJob.set(priority: 1).perform_later("higher")
    cursors.expire_discovery!("*")

    queries = capture_candidate_queries { assert_equal 1, claim(1).size }

    assert_equal 1, queries.size
    assert_includes queries.sole, "id > "
    assert_not_includes queries.sole, "(priority, id) <= ("
    assert_not_nil cursors.position("*")
  end

  test "a row below both the cursor and the watermark waits for the unbounded pass" do
    AddToBufferJob.set(priority: 9).perform_later("seed")
    claim(1)
    seed_position = cursors.position("*")

    AddToBufferJob.set(priority: 1).perform_later("stranded")
    stranded = SolidQueue::ReadyExecution.sole

    # What a rolled back claim or a commit landing after the watermark was read
    # leaves behind: a row below the cursor that the floor also hides
    cursors.record_full_discovery("*", seed_position, stranded.id)

    cursors.expire_discovery!("*")
    assert_empty claim(1)

    cursors.expire_full_discovery!("*")
    assert_equal 1, claim(1).size
  end

  test "the unbounded pass runs on its own cadence" do
    AddToBufferJob.perform_later("seed")
    claim(1)

    assert_not cursors.discovery_due?("*")
    assert_not cursors.full_discovery_due?("*")

    cursors.expire_discovery!("*")
    assert cursors.discovery_due?("*")
    assert_not cursors.full_discovery_due?("*")

    AddToBufferJob.perform_later("next")
    cursors.expire_full_discovery!("*")
    queries = capture_candidate_queries { assert_equal 1, claim(1).size }

    assert_equal 1, queries.size
    assert_not_includes queries.sole, "id > "
    assert_not_includes queries.sole, "(priority, id)"
  end

  test "a zero full discovery interval keeps every discovery pass unbounded" do
    SolidQueue.claim_cursors_full_discovery_interval = 0
    AddToBufferJob.perform_later("seed")
    claim(1)

    AddToBufferJob.perform_later("next")
    cursors.expire_discovery!("*")

    queries = capture_candidate_queries { assert_equal 1, claim(1).size }

    assert_equal 1, queries.size
    assert_not_includes queries.sole, "id > "
  end

  test "a sequence cache above one records no floor and keeps discovery unbounded" do
    with_sequence_cache(5) do
      AddToBufferJob.perform_later("seed")
      claim(1)
      assert_nil cursors.floor("*")

      AddToBufferJob.perform_later("next")
      cursors.expire_discovery!("*")

      queries = capture_candidate_queries { assert_equal 1, claim(1).size }
      assert_not_includes queries.sole, "id > "
    end
  end

  test "jitter only schedules the unbounded pass earlier, never later" do
    now = 0.0
    clocked = SolidQueue::ReadyExecution::ClaimCursors.new(clock: -> { now })

    3.times do
      clocked.record_full_discovery("*", [ 0, 1 ], 1)

      now += 0.7 * SolidQueue.claim_cursors_full_discovery_interval
      assert_not clocked.full_discovery_due?("*")

      now += 0.3 * SolidQueue.claim_cursors_full_discovery_interval
      assert clocked.full_discovery_due?("*")
    end
  end

  test "cursor state is scoped to the datastore" do
    cursors.advance("*", [ 0, 10 ])

    # The pool is the datastore's identity: two datastores never share one
    SolidQueue::ReadyExecution.stubs(:connection_pool).returns(Object.new)
    other_cursors = SolidQueue::ReadyExecution.claim_cursors

    assert_nil other_cursors.position("*")
    other_cursors.advance("*", [ 0, 99 ])

    SolidQueue::ReadyExecution.unstub(:connection_pool)
    assert_equal [ 0, 10 ], cursors.position("*")
  ensure
    other_cursors&.reset!
  end

  test "a table without its own sequence records no floor instead of erroring" do
    SolidQueue::ReadyExecution.stubs(:sequence_name).returns("nonexistent_sequence")
    AddToBufferJob.perform_later("seed")

    assert_equal 1, claim(1).size
    assert_nil cursors.floor("*")
  end

  test "floored passes run with sort plans off and restore the setting" do
    AddToBufferJob.perform_later("seed")
    claim(1)

    AddToBufferJob.perform_later("next")
    cursors.expire_discovery!("*")

    statements = capture_planner_settings { assert_equal 1, claim(1).size }

    # On the graveyard's near-zero row estimates every plan ties, and the tie
    # can land on a legacy job_id index that re-reads every dead tuple
    assert_equal [ "SET LOCAL enable_sort = OFF", "SET LOCAL enable_sort = 'on'" ],
      statements.grep(/enable_sort\b.*(OFF|on)/)
    assert_equal "on", SolidQueue::Record.connection.select_value("SHOW enable_sort")
  end

  test "disabling claim cursors uses the classic path without changing cursor state" do
    SolidQueue.claim_cursors = false
    AddToBufferJob.perform_later("classic")

    queries = capture_candidate_queries { assert_equal 1, claim(1).size }

    assert_equal 1, queries.size
    assert_not_includes queries.sole, "(priority, id) > ("
    assert_nil cursors.position("*")
    assert cursors.discovery_due?("*")
  end

  private
    def claim(limit, queues: "*")
      SolidQueue::ReadyExecution.claim(queues, limit, PROCESS_ID)
    end

    def cursors
      SolidQueue::ReadyExecution.claim_cursors
    end

    def position_of(execution)
      [ execution.priority, execution.id ]
    end

    def claimed_active_job_ids(limit)
      claim(limit).map { |execution| SolidQueue::Job.find(execution.job_id).active_job_id }
    end

    def with_sequence_cache(cache)
      connection = SolidQueue::Record.connection
      sequence = connection.quote_table_name(SolidQueue::ReadyExecution.sequence_name)
      connection.execute("ALTER SEQUENCE #{sequence} CACHE #{cache}")
      yield
    ensure
      connection.execute("ALTER SEQUENCE #{sequence} CACHE 1")
    end

    def capture_planner_settings
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |event|
        sql = event.payload[:sql]
        statements << sql if sql.start_with?("SET LOCAL enable_")
      end

      yield
      statements
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    def capture_candidate_queries
      queries = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |event|
        sql = event.payload[:sql]
        queries << sql if sql.include?("solid_queue_ready_executions") && sql.include?("FOR UPDATE SKIP LOCKED")
      end

      yield
      queries
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end
end

# Uses a second database connection, so rows must be committed and visible
# across connections
class SolidQueue::ClaimCursorsContentionTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  PROCESS_ID = 42

  setup do
    skip "Claim cursors require PostgreSQL" unless SolidQueue::Record.connection_db_config.adapter.match?(/postg/i)
    SolidQueue::ReadyExecution.claim_cursors.reset!
    @original_discovery_interval = SolidQueue.claim_cursors_discovery_interval
    SolidQueue.claim_cursors_discovery_interval = 10.minutes
  end

  teardown do
    SolidQueue::ReadyExecution.claim_cursors.reset!
    SolidQueue.claim_cursors_discovery_interval = @original_discovery_interval if @original_discovery_interval
  end

  test "rows skipped as locked elsewhere are rediscovered after the peer rolls back" do
    AddToBufferJob.perform_later("seed")
    claim(1) # discovery seeds the cursor

    AddToBufferJob.perform_later("contended")
    execution = SolidQueue::ReadyExecution.sole

    peer = SolidQueue::Record.connection_pool.checkout
    peer.execute("BEGIN")
    peer.execute("SELECT id FROM solid_queue_ready_executions WHERE id = #{execution.id} FOR UPDATE")

    assert_empty claim(1) # the only row is locked, so the seek looks empty
    assert_nil SolidQueue::ReadyExecution.claim_cursors.position("*")

    peer.execute("ROLLBACK")

    SolidQueue::ReadyExecution.claim_cursors.expire_discovery!("*")
    claimed = claim(1)

    assert_equal 1, claimed.size
    assert_equal "contended", SolidQueue::Job.find(claimed.sole.job_id).arguments.dig("arguments").first
  ensure
    if peer
      peer.execute("ROLLBACK") rescue nil
      SolidQueue::Record.connection_pool.checkin(peer)
    end
  end

  private
    def claim(limit)
      SolidQueue::ReadyExecution.claim("*", limit, PROCESS_ID)
    end
end
