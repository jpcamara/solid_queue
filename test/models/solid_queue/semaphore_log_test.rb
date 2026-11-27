require "test_helper"

class SolidQueue::SemaphoreLogTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class LimitedToTwoJob < ApplicationJob
    limits_concurrency key: ->(value) { value }, to: 2, group: "semaphore log", duration: 3.minutes

    def perform(value)
    end
  end

  class LimitedToThreeJob < ApplicationJob
    limits_concurrency key: ->(value) { value }, to: 3, group: "semaphore log three", duration: 3.minutes

    def perform(value)
    end
  end

  class LimitedToOneJob < ApplicationJob
    limits_concurrency key: ->(value) { value }, group: "semaphore log one", duration: 3.minutes

    def perform(value)
    end
  end

  class LimitedToZeroJob < ApplicationJob
    limits_concurrency key: ->(value) { value }, to: 0, group: "semaphore log zero", duration: 3.minutes

    def perform(value)
    end
  end

  class CappedJob < ApplicationJob
    limits_concurrency key: ->(value) { value }, group: "semaphore log capped", max_blocked: 1, duration: 3.minutes

    def perform(value)
    end
  end

  class DiscardingJob < ApplicationJob
    limits_concurrency key: ->(value) { value }, group: "semaphore log discarding", on_conflict: :discard, duration: 3.minutes

    def perform(value)
    end
  end

  LOG = "solid_queue_semaphore_log"

  setup do
    skip "Needs PostgreSQL and Active Record 8 or later" unless postgresql? && ActiveRecord.version >= Gem::Version.new("8.0")

    create_log unless connection.table_exists?(LOG)
    connection.execute("TRUNCATE #{LOG}")
    SolidQueue.database_adapter = SolidQueue::DatabaseAdapters::PostgresqlWithSemaphoreLog.new
  end

  teardown do
    SolidQueue.database_adapter = nil
    SolidQueue::Process.destroy_all
    SolidQueue::Batch.destroy_all
  end

  test "limited jobs take their slots from the log, and the semaphores table isn't used" do
    jobs = 3.times.map { enqueue(LimitedToTwoJob, "a") }

    assert_equal [ true, true, false ], jobs.map(&:ready?)
    assert jobs.last.blocked?
    assert_equal [ 1, 0 ], log("a").map { |row| row["value"] }
    assert_equal 1, log("a").map { |row| row["semaphore_id"] }.uniq.size
    assert_equal [ log("a").first["id"] ] * 2, jobs.first(2).map(&:acquired_semaphore_id)
    assert_equal 0, SolidQueue::Semaphore.count
  end

  test "a finished job hands its slot to the next blocked job in one statement after locking the key, adding a row" do
    holder, _other, blocked = 3.times.map { enqueue(LimitedToTwoJob, "a") }

    statements = capturing_statements { assert holder.unblock_next_blocked_job }

    assert blocked.reload.ready?
    assert_not blocked.blocked?
    assert_equal [ 1, 0, 0 ], log("a").map { |row| row["value"] }
    assert_equal holder.acquired_semaphore_id, blocked.acquired_semaphore_id
    assert_equal [ "SELECT", "WITH" ], verbs(statements), statements
    assert_match(/pg_advisory_xact_lock/, statements.first)
    assert_match(/FOR UPDATE SKIP LOCKED.*INSERT INTO solid_queue_semaphore_log/, statements.last)
  end

  test "with no job blocked, a finished job gives its slot back" do
    holder = enqueue(LimitedToTwoJob, "a")

    holder.unblock_next_blocked_job
    assert_equal [ 1, 2 ], log("a").map { |row| row["value"] }
  end

  test "a job enqueued on its own takes its slot in the statement that inserts it, after locking the key" do
    statements = capturing_statements { LimitedToTwoJob.perform_later("a") }

    assert_equal [ "SELECT", "WITH" ], verbs(statements), statements
    assert_match(/pg_advisory_xact_lock/, statements.first)
    assert_match(/INSERT INTO solid_queue_semaphore_log/, statements.last)
  end

  test "a key's first job creates its semaphore and runs, even with a limit of zero, as with the semaphores table" do
    first, second = 2.times.map { enqueue(LimitedToZeroJob, "z") }

    assert first.ready?
    assert second.blocked?
    assert_equal [ -1 ], log("semaphore log zero/z").map { |row| row["value"] }
  end

  test "a semaphore that has expired is gone: its key is free, and its jobs' slots aren't given back to the next one" do
    old = enqueue(LimitedToOneJob, "a")

    travel 4.minutes do
      blocked = enqueue(LimitedToOneJob, "a")
      assert blocked.ready?, "the expired semaphore still counted"
      assert_not_equal old.acquired_semaphore_id, blocked.acquired_semaphore_id

      assert_not SolidQueue::Semaphore.signal(old)
      assert_equal [ 0, 0 ], log(one_key_of("a")).map { |row| row["value"] }
    end
  end

  test "the dispatcher releases a blocked job whose key has a slot free, or whose semaphore expired" do
    enqueue(LimitedToOneJob, "a")
    blocked = enqueue(LimitedToOneJob, "a")
    assert blocked.blocked?

    adapter = SolidQueue::DatabaseAdapters.for(connection)
    assert_equal [], adapter.keys_with_free_slots([ one_key_of("a") ])
    assert_equal [ one_key_of("b") ], adapter.keys_with_free_slots([ one_key_of("a"), one_key_of("b") ])

    travel 4.minutes do
      assert_equal 1, SolidQueue::BlockedExecution.unblock(10)
      assert blocked.reload.ready?
    end
  end

  test "perform_all_later takes the slots for its limited jobs in one statement, after locking their keys" do
    enqueue(LimitedToTwoJob, "a")
    jobs = [ LimitedToTwoJob.new("a"), LimitedToTwoJob.new("a"), LimitedToTwoJob.new("b"), AddToBufferJob.new(1) ]

    statements = capturing_statements { ActiveJob.perform_all_later(jobs) }
    enqueued = SolidQueue::Job.where(active_job_id: jobs.map(&:job_id)).index_by(&:active_job_id)

    assert_equal [ true, false, true, true ], jobs.map { |job| enqueued[job.job_id].ready? }
    assert enqueued[jobs[1].job_id].blocked?
    assert_equal [ 1, 0 ], log("a").map { |row| row["value"] }
    assert_equal [ 1 ], log("b").map { |row| row["value"] }
    assert_equal 1, statements.count { |sql| sql.include?("pg_advisory_xact_lock") }, statements
    assert_equal 1, statements.count { |sql| sql.include?("INSERT INTO solid_queue_semaphore_log") }, statements
  end

  test "jobs released or given back a slot one statement at a time also use the log" do
    holder = enqueue(LimitedToOneJob, "a")
    blocked = enqueue(LimitedToOneJob, "a")

    # Jobs that didn't record their semaphore give their slot back by key
    holder.arguments.delete(SolidQueue::Job::ConcurrencyControls::CONCURRENCY_LOCK_KEY)
    assert SolidQueue::Semaphore.signal(holder)
    assert_equal [ 0, 1 ], log(one_key_of("a")).map { |row| row["value"] }

    blocked.blocked_execution.release_in_steps
    assert blocked.reload.ready?
    assert_equal [ 0, 1, 0 ], log(one_key_of("a")).map { |row| row["value"] }
  end

  test "while writes are prevented, slots are neither taken nor given back" do
    holder = enqueue(LimitedToOneJob, "a")

    SolidQueue::Record.while_preventing_writes do
      assert_raises(ActiveRecord::ReadOnlyError) { SolidQueue::Semaphore.wait(holder) }
      assert_raises(ActiveRecord::ReadOnlyError) { SolidQueue::Semaphore.signal(holder) }
    end
    assert_equal [ 0 ], log(one_key_of("a")).map { |row| row["value"] }
  end

  test "a limited job enqueued in a REPEATABLE READ transaction fails, as it couldn't see the latest state" do
    error = assert_raises(SolidQueue::Job::EnqueueError) do
      SolidQueue::Record.transaction(isolation: :repeatable_read) { LimitedToOneJob.perform_later("a") }
    end

    assert_match(/needs READ COMMITTED, not REPEATABLE READ/, error.message)
    assert_empty log(one_key_of("a"))
  end

  test "callers on a key take turns, and each sees what the one before it committed" do
    holding = Concurrent::Event.new
    done = Concurrent::Event.new

    holder = Thread.new do
      SolidQueue::Record.transaction do
        enqueue(LimitedToOneJob, "a")
        holding.set
        done.wait(30)
      end
    end
    holding.wait(5)

    waiter = Thread.new { enqueue(LimitedToOneJob, "a") }
    wait_for { advisory_lock_waiters > 0 }
    assert waiter.alive?, "the second caller didn't wait for the first"

    done.set
    holder.join
    assert waiter.value.blocked?, "the second caller took a slot the first had taken"
  ensure
    done&.set
    [ holder, waiter ].compact.each { |thread| thread.join(5) }
  end

  test "a limited job enqueued into a batch waits for the batch before locking its key, as other enqueues do" do
    batch = SolidQueue::Batch.create!
    locked = Concurrent::Event.new
    done = Concurrent::Event.new

    holder = Thread.new do
      SolidQueue::Record.transaction do
        SolidQueue::Batch.lock("FOR NO KEY UPDATE").find(batch.id)
        locked.set
        done.wait(30)
      end
    end
    locked.wait(5)

    enqueuer = Thread.new { SolidQueue::Batch.wrap_in_batch_context(batch.id) { enqueue(LimitedToOneJob, "a") } }
    wait_for { lock_waiters > 0 }
    assert enqueuer.alive?, "the enqueue didn't wait for the batch"
    assert_equal 0, advisory_locks_held, "the enqueue locked its key before its batch"

    done.set
    assert enqueuer.value.ready?
  ensure
    done&.set
    [ holder, enqueuer ].compact.each { |thread| thread.join(5) }
  end

  test "concurrent enqueues and hand-overs on one key hand out exactly the limit" do
    key = "semaphore log three/k"
    16.times.map { Thread.new { SolidQueue::Record.connection_pool.with_connection { 25.times { LimitedToThreeJob.perform_later("k") } } } }.each(&:join)

    jobs = SolidQueue::Job.where(concurrency_key: key)
    ready = jobs.select(&:ready?)
    assert_equal 400, jobs.count
    assert_equal 3, ready.size
    assert_equal 397, jobs.count(&:blocked?)
    assert_equal 0, log(key).last["value"]
    assert_equal [ log(key).first["id"] ], ready.map(&:acquired_semaphore_id).uniq

    ready.map { |job| Thread.new { SolidQueue::Record.connection_pool.with_connection { job.unblock_next_blocked_job } } }.each(&:join)
    assert_equal 6, jobs.reload.count(&:ready?)
    assert_equal 0, log(key).last["value"]
  end

  test "a job over max_blocked is discarded without locking its key" do
    2.times { enqueue(CappedJob, "a") }

    statements = capturing_statements do
      assert_no_difference -> { SolidQueue::Job.count } do
        CappedJob.perform_later("a")
      end
    end

    assert_empty statements.grep(/pg_advisory_xact_lock/), statements
    assert_equal [ 0 ], log("semaphore log capped/a").map { |row| row["value"] }
  end

  test "a job over max_blocked takes the slot of a semaphore that expired" do
    2.times { enqueue(CappedJob, "a") }

    travel 4.minutes do
      assert enqueue(CappedJob, "a").ready?
    end
  end

  test "a capped job is inserted, ready or blocked, by one statement after its key is locked" do
    statements = 2.times.map { capturing_statements { CappedJob.perform_later("a") } }

    statements.each { |enqueue| assert_equal [ "SELECT", "SELECT", "WITH" ], verbs(enqueue), enqueue }
    assert_match(/pg_advisory_xact_lock/, statements.first.second)
    assert_equal [ 0 ], log("semaphore log capped/a").map { |row| row["value"] }
  end

  test "a capped job finding max_blocked jobs blocked once its key is locked isn't inserted" do
    2.times { enqueue(CappedJob, "a") }
    adapter = SolidQueue::Job.database_adapter
    adapter.stubs(:full_with_blocked?).returns(false)

    statements = capturing_statements { CappedJob.perform_later("a") }

    assert_equal [ "SELECT", "WITH" ], verbs(statements), statements
    assert_equal 2, SolidQueue::Job.count
    assert_equal [ 0 ], log("semaphore log capped/a").map { |row| row["value"] }
  ensure
    adapter&.unstub(:full_with_blocked?)
  end

  test "a job that discards on conflict is inserted by one statement after its key is locked, and isn't without a slot" do
    statements = 2.times.map { capturing_statements { DiscardingJob.perform_later("a") } }

    statements.each { |enqueue| assert_equal [ "SELECT", "WITH" ], verbs(enqueue), enqueue }
    assert_equal 1, SolidQueue::Job.count
    assert SolidQueue::Job.sole.ready?
    assert_equal [ 0 ], log("semaphore log discarding/a").map { |row| row["value"] }
  end

  test "concurrent enqueues on a max_blocked key keep its cap" do
    16.times.map do |thread|
      Thread.new do
        SolidQueue::Record.connection_pool.with_connection do
          thread.even? ? 25.times { CappedJob.perform_later("k") } : 5.times { ActiveJob.perform_all_later(5.times.map { CappedJob.new("k") }) }
        end
      end
    end.each(&:join)

    jobs = SolidQueue::Job.where(concurrency_key: "semaphore log capped/k")
    assert_equal 2, jobs.count
    assert_equal 1, jobs.count(&:ready?)
    assert_equal 1, jobs.count(&:blocked?)
  end

  test "maintenance deletes the rows newer ones replaced and the expired ones, in batches, keeping each key's semaphore" do
    insert_row(id: 1, key: "full", value: 1)
    insert_row(id: 2, key: "expired", value: 1, expires_at: 1.minute.ago)
    insert_row(id: 3, key: "full", value: 0)
    insert_row(id: 4, key: "alone", value: 1)
    connection.execute("SELECT setval('#{LOG}_id_seq', 100)")

    statements = capturing_statements { SolidQueue::DatabaseAdapters.for(connection).expire_semaphores(1) }

    assert_equal [ 3, 4 ], connection.select_values("SELECT id FROM #{LOG} ORDER BY id")
    assert_equal 3, statements.grep(/\ADELETE/).size, statements
    assert enqueue(LimitedToOneJob, "full").blocked?
    assert enqueue(LimitedToOneJob, "expired").ready?
  end

  private
    def connection
      SolidQueue::Record.connection
    end

    def create_log
      load File.expand_path("../../../lib/generators/solid_queue/semaphore_log/templates/db/create_solid_queue_semaphore_log.rb", __dir__)
      ActiveRecord::Migration.suppress_messages do
        SolidQueue::Record.connection_pool.with_connection { |c| CreateSolidQueueSemaphoreLog.new.exec_migration(c, :up) }
      end
    end

    def enqueue(job_class, *arguments)
      active_job = job_class.perform_later(*arguments)
      SolidQueue::Job.find_by!(active_job_id: active_job.job_id)
    end

    def log(key)
      connection.select_all("SELECT * FROM #{LOG} WHERE key = $1 ORDER BY id", "log", [ key_of(key) ]).to_a
    end

    # Every job here is in a group whose key ends with "log"
    def key_of(key)
      key.include?("/") ? key : "semaphore log/#{key}"
    end

    def one_key_of(key)
      "semaphore log one/#{key}"
    end

    def insert_row(id:, key:, value:, expires_at: 3.minutes.from_now)
      connection.exec_query("INSERT INTO #{LOG} (id, key, semaphore_id, value, expires_at, created_at) VALUES ($1, $2, $1, $3, $4, $5)",
        "insert", [ id, one_key_of(key), value, expires_at.utc, Time.now.utc ])
    end

    def lock_waiters
      connection.select_value("SELECT count(*) FROM pg_locks WHERE NOT granted")
    end

    def advisory_locks_held
      connection.select_value("SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND granted")
    end

    def advisory_lock_waiters
      connection.select_value("SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND NOT granted")
    end

    def wait_for(timeout: 5)
      deadline = Time.now + timeout
      sleep 0.01 until yield || Time.now > deadline
    end

    def capturing_statements(&block)
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        statements << payload[:sql].squish unless payload[:name] == "SCHEMA" || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|SAVEPOINT|RELEASE)/)
      end
      block.call
      statements
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    def verbs(statements)
      statements.map { |sql| sql[/\A\w+/] }
    end

    def postgresql?
      SolidQueue::Record.connection.adapter_name == "PostgreSQL"
    end
end
