require "test_helper"

class SolidQueue::JobUnblockInOneStatementTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class LimitedToTwoJob < ApplicationJob
    limits_concurrency key: ->(value) { value }, to: 2, group: "unblock", duration: 3.minutes

    def perform(value)
    end
  end

  class LimitedToThreeJob < ApplicationJob
    limits_concurrency key: ->(value) { value }, to: 3, group: "unblock", duration: 5.minutes

    def perform(value)
    end
  end

  class LimitedToZeroJob < ApplicationJob
    limits_concurrency key: ->(value) { value }, to: 0, group: "unblock zero"

    def perform(value)
    end
  end

  LOCK_KEY = SolidQueue::Job::ConcurrencyControls::CONCURRENCY_LOCK_KEY

  setup do
    skip "Needs Active Record 8 or later" if ActiveRecord.version < Gem::Version.new("8.0")
  end

  teardown do
    SolidQueue::Process.destroy_all
  end

  test "a job hands its slot to the next blocked job, which is made ready, in one statement" do
    holder, blocked = holder_and_blocked
    semaphore = semaphore_of(holder)
    semaphore.update_column(:expires_at, 1.minute.from_now)
    arguments = blocked.job.arguments

    statements = capturing_statements { assert holder.unblock_next_blocked_job }

    job = SolidQueue::Job.find(blocked.job_id)
    assert job.ready?
    assert_not SolidQueue::BlockedExecution.exists?(blocked.id)
    assert_equal 0, semaphore.reload.value
    assert_in_delta 3.minutes.from_now, semaphore.expires_at, 5.seconds

    lock = { "semaphore_id" => semaphore.id, "limit" => 2 }
    assert_equal arguments.merge(LOCK_KEY => lock), job.arguments
    assert_equal JSON.dump(arguments.merge(LOCK_KEY => lock)), job.arguments_before_type_cast

    if postgresql?
      assert_equal [ "WITH" ], verbs(statements), statements
      assert_match(/\AWITH held AS .*FOR UPDATE.*FOR UPDATE SKIP LOCKED.*UPDATE "solid_queue_semaphores".*UPDATE "solid_queue_jobs".*INSERT INTO "solid_queue_ready_executions".*DELETE FROM "solid_queue_blocked_executions"/, statements.first)
    else
      assert_operator statements.size, :>, 1
    end
  end

  test "it leaves everything as giving the slot back and releasing the blocked job did" do
    states = [ true, false ].map do |in_one_statement|
      holder, blocked = holder_and_blocked(in_one_statement.to_s)

      if in_one_statement
        holder.unblock_next_blocked_job
      else
        SolidQueue::Job::ConcurrencyControls.instance_method(:unblock_next_blocked_job).bind_call(holder)
      end

      job, semaphore = SolidQueue::Job.find(blocked.job_id), semaphore_of(holder)
      assert_in_delta 3.minutes.from_now, semaphore.expires_at, 5.seconds

      [ semaphore.value, job.arguments[LOCK_KEY] == { "semaphore_id" => semaphore.id, "limit" => 2 },
        job.arguments_before_type_cast.sub(/"semaphore_id":\d+/, "").gsub(/[0-9a-f-]{36}|true|false|\d{4}-[\d:.T-]+Z/, ""),
        job.ready_execution.attributes.values_at("queue_name", "priority"), SolidQueue::BlockedExecution.exists?(blocked.id),
        SolidQueue::Job.find(holder.id).attributes.except("id", "active_job_id", "arguments", "concurrency_key", "created_at", "updated_at", "scheduled_at") ]
    end

    assert_equal states.second, states.first
    assert_equal [ 0, true ], states.first.first(2)
  end

  test "the job is made ready on its own queue and priority" do
    holder, blocked = holder_and_blocked
    blocked.update_columns(queue_name: "elsewhere", priority: 7)
    SolidQueue::Job.where(id: blocked.job_id).update_all(queue_name: "background", priority: 3)

    assert holder.unblock_next_blocked_job

    assert_equal [ "background", 3 ], SolidQueue::ReadyExecution.find_by!(job_id: blocked.job_id).attributes.values_at("queue_name", "priority")
  end

  test "the slot goes to the next blocked job by priority, then by job, and only to one" do
    holder, first = holder_and_blocked
    second = SolidQueue::BlockedExecution.find_by!(job_id: LimitedToTwoJob.perform_later("key").provider_job_id)
    urgent = SolidQueue::BlockedExecution.find_by!(job_id: LimitedToTwoJob.set(priority: -1).perform_later("key").provider_job_id)
    other_key = holder_and_blocked("other").last

    assert holder.unblock_next_blocked_job
    assert_equal [ urgent.job_id ], ready_among(first, second, urgent, other_key)

    assert SolidQueue::Job.find(urgent.job_id).unblock_next_blocked_job
    assert_equal [ first.job_id, urgent.job_id ], ready_among(first, second, urgent, other_key)
    assert_equal 0, semaphore_of(holder).value
  end

  test "a blocked job locked by someone else is skipped, as before" do
    skip "Needs SKIP LOCKED" if sqlite?

    holder, first = holder_and_blocked
    second = SolidQueue::BlockedExecution.find_by!(job_id: LimitedToTwoJob.perform_later("key").provider_job_id)
    locked, release = Concurrent::Event.new, Concurrent::Event.new

    locker = Thread.new do
      SolidQueue::Record.connection_pool.with_connection do
        SolidQueue::Record.transaction do
          SolidQueue::BlockedExecution.lock.find(first.id)
          locked.set
          release.wait(5)
        end
      end
    end

    locked.wait(5)
    assert holder.unblock_next_blocked_job
    release.set
    locker.join(5)

    assert_equal [ second.job_id ], ready_among(first, second)
  end

  test "with no job blocked, the slot is given back to the semaphore" do
    2.times { LimitedToTwoJob.perform_later("key") }
    holder = SolidQueue::Job.last
    semaphore = semaphore_of(holder)
    semaphore.update_column(:expires_at, 1.minute.from_now)

    statements = capturing_statements { assert_not holder.unblock_next_blocked_job }

    assert_equal 1, semaphore.reload.value
    assert_in_delta 3.minutes.from_now, semaphore.expires_at, 5.seconds
    # Looking again for a job blocked meanwhile, as before
    assert_equal [ "WITH", "BEGIN", "SELECT", "COMMIT" ], verbs(statements), statements if postgresql?
  end

  test "a job blocked while the slot is given back is released, as before" do
    skip "Needs row locks" if sqlite?

    2.times { LimitedToTwoJob.perform_later("key") }
    holder = SolidQueue::Job.last
    semaphore = semaphore_of(holder)
    locked, waiting, blocked_job_id = Concurrent::Event.new, Concurrent::Event.new, nil

    # As an enqueue that finds no slot does: it locks the semaphore, then
    # blocks its job, here once the slot is being given back
    enqueue = Thread.new do
      SolidQueue::Record.connection_pool.with_connection do
        SolidQueue::Record.transaction do
          SolidQueue::Semaphore.lock.find(semaphore.id)
          locked.set
          waiting.wait(5)
          blocked_job_id = LimitedToTwoJob.perform_later("key").provider_job_id
        end
      end
    end

    locked.wait(5)
    unblock = Thread.new { SolidQueue::Record.connection_pool.with_connection { holder.unblock_next_blocked_job } }
    wait_for_lock_wait
    waiting.set
    [ enqueue, unblock ].each { |thread| thread.join(5) }

    assert SolidQueue::Job.find(blocked_job_id).ready?
    assert_equal 0, semaphore.reload.value
  end

  test "it waits for the semaphore before it locks the blocked job" do
    skip "Needs the statement" unless postgresql?

    holder, blocked = holder_and_blocked
    locked, waiting = Concurrent::Event.new, Concurrent::Event.new

    other = Thread.new do
      SolidQueue::Record.connection_pool.with_connection do
        SolidQueue::Record.transaction do
          SolidQueue::Semaphore.lock.find(semaphore_of(holder).id)
          locked.set
          waiting.wait(5)
          # As discarding it would
          SolidQueue::BlockedExecution.lock("FOR UPDATE NOWAIT").find(blocked.id)
        end
      end
    end
    other.report_on_exception = false

    locked.wait(5)
    unblock = Thread.new { SolidQueue::Record.connection_pool.with_connection { holder.unblock_next_blocked_job } }
    wait_for_lock_wait
    waiting.set

    assert_nothing_raised { other.value }
    assert unblock.value
    assert SolidQueue::Job.find(blocked.job_id).ready?
  end

  test "a slot handed over while someone else changes the semaphore is handed over once they're done" do
    skip "Needs row locks" if sqlite?

    holder, blocked = holder_and_blocked
    semaphore = semaphore_of(holder)
    locked = Concurrent::Event.new

    other = Thread.new do
      SolidQueue::Record.connection_pool.with_connection do
        SolidQueue::Record.transaction do
          SolidQueue::Semaphore.where(id: semaphore.id).update_all(expires_at: 1.minute.from_now)
          locked.set
          sleep 0.5
        end
      end
    end

    locked.wait(5)
    assert holder.unblock_next_blocked_job
    other.join(5)

    assert SolidQueue::Job.find(blocked.job_id).ready?
    assert_equal semaphore.id, SolidQueue::Job.find(blocked.job_id).acquired_semaphore_id
    assert_equal 0, semaphore.reload.value
    assert_in_delta 3.minutes.from_now, semaphore.expires_at, 5.seconds
  end

  test "when its semaphore is gone, or already has all its slots, nothing changes" do
    holder, blocked = holder_and_blocked("gone")
    semaphore_of(holder).destroy!
    replacement = SolidQueue::Semaphore.create!(key: holder.concurrency_key, value: 0, expires_at: 1.minute.from_now)

    assert_nothing_changed(blocked, replacement) { assert_not holder.unblock_next_blocked_job }

    holder, blocked = holder_and_blocked("full")
    semaphore = semaphore_of(holder)
    semaphore.update_columns(value: 2, expires_at: 1.minute.from_now)

    assert_nothing_changed(blocked, semaphore) { assert_not holder.unblock_next_blocked_job }
  end

  test "the slot is given back within the limit the job got it under" do
    holder, blocked = holder_and_blocked
    holder.arguments[LOCK_KEY]["limit"] = 1
    holder.update_column(:arguments, holder.arguments)
    semaphore = semaphore_of(holder)
    semaphore.update_columns(value: 1, expires_at: 1.minute.from_now)

    assert_nothing_changed(blocked, semaphore) { assert_not holder.reload.unblock_next_blocked_job }
  end

  test "a job whose concurrency key changed gives its slot back to its semaphore, and the blocked job takes one on its key, as before" do
    holder, blocked = holder_and_blocked("old")
    other_holder, other_blocked = holder_and_blocked("new")
    semaphore, other_semaphore = semaphore_of(holder), semaphore_of(other_holder)
    holder.update_column(:concurrency_key, other_holder.concurrency_key)

    assert_nothing_changed(other_blocked, other_semaphore) { assert_not holder.unblock_next_blocked_job }

    assert_equal 1, semaphore.reload.value
    assert SolidQueue::BlockedExecution.exists?(blocked.id)
  end

  test "with a limit of zero, the slot is given back and the blocked job stays blocked, as before" do
    2.times { LimitedToZeroJob.perform_later("key") }
    holder, blocked = SolidQueue::Job.last(2).first, SolidQueue::BlockedExecution.find_by!(job_id: SolidQueue::Job.last.id)
    semaphore = semaphore_of(holder)
    assert_equal(-1, semaphore.value)

    statements = capturing_statements { assert_not holder.unblock_next_blocked_job }

    assert_equal 0, semaphore.reload.value
    assert SolidQueue::BlockedExecution.exists?(blocked.id)
    assert_not SolidQueue::ReadyExecution.exists?(job_id: blocked.job_id)
    assert_equal [ "WITH held", "BEGIN" ], statements.first(2).map { |sql| sql[/\A\w+( held)?/] }, statements if postgresql?
  end

  test "when blocked jobs locked by others aren't skipped, the slot is given back as before" do
    holder, blocked = holder_and_blocked

    skipping, SolidQueue.use_skip_locked = SolidQueue.use_skip_locked, false
    assert_no_one_statement_unblock { assert holder.unblock_next_blocked_job }

    assert SolidQueue::Job.find(blocked.job_id).ready?
  ensure
    SolidQueue.use_skip_locked = skipping
  end

  test "a blocked job of another class is released as before, with its own limit and duration" do
    2.times { LimitedToTwoJob.perform_later("key") }
    holder = SolidQueue::Job.last
    blocked = SolidQueue::BlockedExecution.find_by!(job_id: LimitedToThreeJob.perform_later("key").provider_job_id)
    assert_equal holder.concurrency_key, blocked.concurrency_key

    statements = capturing_statements { assert holder.unblock_next_blocked_job }

    job, semaphore = SolidQueue::Job.find(blocked.job_id), semaphore_of(holder)
    assert job.ready?
    assert_equal({ "semaphore_id" => semaphore.id, "limit" => 3 }, job.arguments[LOCK_KEY])
    assert_equal 0, semaphore.value
    assert_in_delta 5.minutes.from_now, semaphore.expires_at, 5.seconds
    assert_equal [ "WITH", "BEGIN", "SELECT", "SELECT", "WITH", "COMMIT" ], verbs(statements), statements if postgresql?
  end

  test "a blocked job with another concurrency key takes its slot on its own key, as before" do
    holder, blocked = holder_and_blocked
    SolidQueue::Job.where(id: blocked.job_id).update_all(concurrency_key: "unblock/own")

    holder.unblock_next_blocked_job

    assert SolidQueue::Job.find(blocked.job_id).ready?
    assert_equal 1, semaphore_of(holder).value
    assert_equal 1, SolidQueue::Semaphore.find_by!(key: "unblock/own").value
  end

  test "a blocked job whose arguments can't take the slot is released as before" do
    recorded = { LOCK_KEY => { "semaphore_id" => nil, "limit" => nil } }

    { "recorded" => ->(arguments) { JSON.dump(JSON.parse(arguments).merge(recorded)) }, "newline" => ->(arguments) { "#{arguments}\n" }, "empty" => ->(arguments) { "{}" }, "blank" => ->(arguments) { "{ \n}" },
      "nested" => ->(arguments) { JSON.dump(JSON.parse(arguments).merge("arguments" => [ recorded ])) } }.each do |key, change|
      holder, blocked = holder_and_blocked(key)
      SolidQueue::Job.where(id: blocked.job_id).update_all([ "arguments = ?", change.(blocked.job.arguments_before_type_cast) ])

      statements = capturing_statements { assert holder.unblock_next_blocked_job }

      job = SolidQueue::Job.find(blocked.job_id)
      assert job.ready?, key
      assert_equal 0, semaphore_of(holder).value
      assert_nothing_raised { JSON.parse(job.arguments_before_type_cast) }
      assert_equal 1, job.arguments_before_type_cast.scan(/"#{LOCK_KEY}":/o).size - (key == "nested" ? 1 : 0), key
      assert_equal [ "WITH held", "BEGIN" ], statements.first(2).map { |sql| sql[/\A\w+( held)?/] }, statements if postgresql?
    end
  end

  test "a job whose class doesn't load, or that didn't record its semaphore, gives its slot back as before" do
    holder, blocked = holder_and_blocked("gone")
    SolidQueue::Job.where(id: holder.id).update_all(class_name: "GoneJob")
    assert_no_one_statement_unblock { assert SolidQueue::Job.find(holder.id).unblock_next_blocked_job }
    assert SolidQueue::Job.find(blocked.job_id).ready?

    holder, blocked = holder_and_blocked("unrecorded")
    holder.update_column(:arguments, holder.arguments.except(LOCK_KEY))
    assert_no_one_statement_unblock { assert SolidQueue::Job.find(holder.id).unblock_next_blocked_job }
    assert SolidQueue::Job.find(blocked.job_id).ready?

    holder, blocked = holder_and_blocked("no slot")
    holder.update_column(:arguments, holder.arguments.merge(LOCK_KEY => { "semaphore_id" => nil, "limit" => nil }))
    assert_no_one_statement_unblock { assert_not SolidQueue::Job.find(holder.id).unblock_next_blocked_job }
    assert_not SolidQueue::Job.find(blocked.job_id).ready?
  end

  test "while writes are prevented, the slot is given back as before, and fails to be" do
    holder, blocked = holder_and_blocked

    assert_nothing_changed(blocked, semaphore_of(holder)) do
      assert_no_one_statement_unblock do
        assert_raises(ActiveRecord::ReadOnlyError) do
          SolidQueue::Record.while_preventing_writes { holder.unblock_next_blocked_job }
        end
      end
    end
  end

  test "the release is instrumented as before" do
    holder, blocked = holder_and_blocked

    events = []
    callback = ->(event) { events << event.payload }
    ActiveSupport::Notifications.subscribed(callback, "release_blocked.solid_queue") do
      holder.unblock_next_blocked_job
      # Nothing blocked now
      SolidQueue::Job.find(blocked.job_id).unblock_next_blocked_job
    end

    assert_equal [ { job_id: blocked.job_id, concurrency_key: holder.concurrency_key, released: true } ], events
  end

  test "a query cached before the slot is handed over isn't served after it" do
    holder, blocked = holder_and_blocked

    SolidQueue::Record.cache do
      assert_equal 0, SolidQueue::ReadyExecution.where(job_id: blocked.job_id).count
      holder.unblock_next_blocked_job

      assert_equal 1, SolidQueue::ReadyExecution.where(job_id: blocked.job_id).count
    end
  end

  test "a job that finishes, fails or is discarded hands its slot over" do
    process = SolidQueue::Process.register(kind: "Worker", pid: 42, name: "worker-123", metadata: {})

    holder, blocked = holder_and_blocked("finished")
    claimed = SolidQueue::ReadyExecution.claim("*", 1, process.id).first
    statements = capturing_statements { claimed.perform }
    assert SolidQueue::Job.find(blocked.job_id).ready?
    # The finish, then the handover
    assert_equal [ "WITH claim", "WITH held" ], statements.map { |sql| sql[/\A\w+ \w+/] }, statements if postgresql?
    SolidQueue::ReadyExecution.delete_all

    holder, blocked = holder_and_blocked("failed")
    SolidQueue::ReadyExecution.where.not(job_id: holder.id).delete_all
    claimed = SolidQueue::ReadyExecution.claim("*", 1, process.id).first
    assert_equal holder.id, claimed.job_id
    assert_one_statement_unblock { claimed.failed_with(RuntimeError.new("failed")) }
    assert SolidQueue::Job.find(blocked.job_id).ready?
    SolidQueue::ReadyExecution.delete_all

    holder, blocked = holder_and_blocked("discarded")
    assert_one_statement_unblock { holder.discard }
    assert SolidQueue::Job.find(blocked.job_id).ready?
    assert_equal 0, semaphore_of(blocked.job).value
  end

  test "the statement is prepared" do
    skip "Needs prepared statements" unless postgresql? && SolidQueue::Record.connection.prepared_statements

    SolidQueue::Record.connection_pool.with_connection do |connection|
      prepared = -> { connection.select_value("SELECT count(*) FROM pg_prepared_statements WHERE statement LIKE 'WITH held AS%'") }
      first, second = holder_and_blocked("first").first, holder_and_blocked("second").first

      assert first.unblock_next_blocked_job
      before = prepared.()
      assert second.unblock_next_blocked_job

      assert_operator before, :>=, 1
      assert_equal before, prepared.()
    end
  end

  private
    # Two jobs fill the slots of the key; the third is blocked
    def holder_and_blocked(key = "key")
      jobs = 3.times.map { LimitedToTwoJob.perform_later(key) }
      [ SolidQueue::Job.find(jobs.first.provider_job_id), SolidQueue::BlockedExecution.find_by!(job_id: jobs.last.provider_job_id) ]
    end

    def semaphore_of(job)
      SolidQueue::Semaphore.find_by!(key: job.concurrency_key)
    end

    def ready_among(*blocked)
      SolidQueue::ReadyExecution.where(job_id: blocked.map(&:job_id)).pluck(:job_id).sort
    end

    def assert_nothing_changed(blocked, semaphore)
      arguments = SolidQueue::Job.find(blocked.job_id).arguments_before_type_cast
      value, expires_at = semaphore.reload.values_at(:value, :expires_at)

      yield

      assert SolidQueue::BlockedExecution.exists?(blocked.id)
      assert_not SolidQueue::ReadyExecution.exists?(job_id: blocked.job_id)
      assert_equal arguments, SolidQueue::Job.find(blocked.job_id).arguments_before_type_cast
      assert_equal [ value, expires_at ], semaphore.reload.values_at(:value, :expires_at)
    end

    # The slot handed over by the statement, with nothing released as before after it
    def assert_one_statement_unblock(&block)
      statements = capturing_statements(&block)
      return unless postgresql?

      assert_equal 1, statements.count { |sql| sql.start_with?("WITH held") }, statements
      assert statements.none? { |sql| sql.include?("FOR UPDATE SKIP LOCKED") && !sql.start_with?("WITH held") }, statements
    end

    # Until the handover statement waits for a lock
    def wait_for_lock_wait
      if postgresql?
        wait_while_with_timeout!(5) do
          SolidQueue::Record.connection.select_value(<<~SQL).zero?
            SELECT count(*) FROM pg_stat_activity
            WHERE wait_event_type = 'Lock' AND datname = current_database() AND query LIKE 'WITH held%'
          SQL
        end
      else
        sleep 0.5
      end
    end

    def assert_no_one_statement_unblock(&block)
      statements = capturing_statements(&block)
      assert statements.none? { |sql| sql.start_with?("WITH held") }, statements
    end

    def postgresql?
      SolidQueue::Record.connection.adapter_name == "PostgreSQL"
    end

    def sqlite?
      SolidQueue::Record.connection.adapter_name == "SQLite"
    end

    def verbs(statements)
      statements.map { |sql| sql[/\A\w+/] }
    end

    def capturing_statements(&block)
      statements = []
      callback = ->(*, payload) { statements << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:sql] !~ /solid_queue|\A(BEGIN|COMMIT|ROLLBACK)/ }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
      statements
    end
end
