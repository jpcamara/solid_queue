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

  test "a finished job hands its slot to the next blocked job in one statement, adding a row" do
    holder, _other, blocked = 3.times.map { enqueue(LimitedToTwoJob, "a") }

    statements = capturing_statements { assert holder.unblock_next_blocked_job }

    assert blocked.reload.ready?
    assert_not blocked.blocked?
    assert_equal [ 1, 0, 0 ], log("a").map { |row| row["value"] }
    assert_equal holder.acquired_semaphore_id, blocked.acquired_semaphore_id
    assert_equal [ "WITH" ], verbs(statements), statements
    assert_match(/solid_queue_semaphore_held.*FOR UPDATE SKIP LOCKED.*solid_queue_semaphore_signal/, statements.first)
  end

  test "with no job blocked, a finished job gives its slot back" do
    holder = enqueue(LimitedToTwoJob, "a")

    holder.unblock_next_blocked_job
    assert_equal [ 1, 2 ], log("a").map { |row| row["value"] }
  end

  test "a job enqueued on its own takes its slot in the statement that inserts it" do
    statements = capturing_statements { LimitedToTwoJob.perform_later("a") }

    assert_equal [ "WITH" ], verbs(statements), statements
    assert_match(/solid_queue_semaphore_wait/, statements.first)
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

  test "perform_all_later takes the slots for its limited jobs in one statement" do
    enqueue(LimitedToTwoJob, "a")
    jobs = [ LimitedToTwoJob.new("a"), LimitedToTwoJob.new("a"), LimitedToTwoJob.new("b"), AddToBufferJob.new(1) ]

    statements = capturing_statements { ActiveJob.perform_all_later(jobs) }
    enqueued = SolidQueue::Job.where(active_job_id: jobs.map(&:job_id)).index_by(&:active_job_id)

    assert_equal [ true, false, true, true ], jobs.map { |job| enqueued[job.job_id].ready? }
    assert enqueued[jobs[1].job_id].blocked?
    assert_equal [ 1, 0 ], log("a").map { |row| row["value"] }
    assert_equal [ 1 ], log("b").map { |row| row["value"] }
    assert_equal 1, statements.count { |sql| sql.include?("solid_queue_semaphore_wait_all") }, statements
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

  test "rotation copies each key's newest live row out of the partition written to two periods ago, and truncates it" do
    stale = partition(part + 1)
    current = partition(part)
    insert_row(stale, id: 1, key: "live", value: 1)
    insert_row(stale, id: 2, key: "expired", value: 1, expires_at: 1.minute.ago)
    insert_row(stale, id: 3, key: "moved on", value: 1)
    insert_row(current, id: 4, key: "moved on", value: 0)

    assert_equal 1, SolidQueue::DatabaseAdapters.for(connection).expire_semaphores(100)

    assert_equal 0, connection.select_value("SELECT count(*) FROM #{stale}")
    assert_equal [ [ 1, key_of("live"), 1 ], [ 4, key_of("moved on"), 0 ] ], connection.select_rows("SELECT id, key, value FROM #{current} ORDER BY id")
    assert enqueue(LimitedToTwoJob, "live").ready?
    assert_equal [ 1, 0 ], log("live").map { |row| row["value"] }
  end

  test "rotation is left for later while a transaction that read the log is open" do
    stale = partition(part + 1)
    insert_row(stale, id: 1, key: "live", value: 1)

    reader = SolidQueue::Record.connection_pool.checkout
    reader.begin_db_transaction
    reader.select_value("SELECT count(*) FROM #{LOG}")

    assert_nil SolidQueue::DatabaseAdapters.for(connection).expire_semaphores(100)
    assert_equal 1, connection.select_value("SELECT count(*) FROM #{stale}")
  ensure
    reader&.rollback_db_transaction
    SolidQueue::Record.connection_pool.checkin(reader) if reader
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

    def part
      connection.select_value("SELECT solid_queue_semaphore_log_part()")
    end

    def partition(part)
      "#{LOG}_#{part % 3}"
    end

    def insert_row(table, id:, key:, value:, expires_at: 3.minutes.from_now)
      connection.exec_query("INSERT INTO #{table} (id, part, key, semaphore_id, value, expires_at, created_at) VALUES ($1, $2, $3, $1, $4, $5, $6)",
        "insert", [ id, table[-1].to_i, key_of(key), value, expires_at.utc, Time.now.utc ])
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
