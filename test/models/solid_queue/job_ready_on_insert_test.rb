require "test_helper"

class SolidQueue::JobReadyOnInsertTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class LimitedJob < ApplicationJob
    limits_concurrency key: ->(value) { value }

    def perform(value)
    end
  end

  class LimitedToTwoJob < ApplicationJob
    limits_concurrency key: ->(value) { value }, to: 2

    def perform(value)
    end
  end

  class DiscardingJob < ApplicationJob
    limits_concurrency key: ->(value) { value }, on_conflict: :discard

    def perform(value)
    end
  end

  class CappedJob < ApplicationJob
    limits_concurrency key: ->(value) { value }, max_blocked: 1

    def perform(value)
    end
  end

  setup do
    skip "Needs Active Record 8 or later" if ActiveRecord.version < Gem::Version.new("8.0")

    # Active Record 8.0 begins the open transaction to load a model's schema,
    # which the first enqueue in a process would do
    [ SolidQueue::Semaphore, SolidQueue::BlockedExecution, SolidQueue::Batch, SolidQueue::BatchExecution ].each(&:load_schema)
  end

  teardown do
    SolidQueue::Batch.destroy_all
  end

  test "a due job is inserted with its ready execution in one statement" do
    job = nil
    statements = capturing_statements { job = AddToBufferJob.perform_later(1) }

    assert job.successfully_enqueued?
    solid_queue_job = SolidQueue::Job.find(job.provider_job_id)
    assert solid_queue_job.ready?
    assert_equal [ solid_queue_job.queue_name, solid_queue_job.priority ], solid_queue_job.ready_execution.attributes.values_at("queue_name", "priority")

    if postgresql?
      assert_equal [ "WITH" ], verbs(statements), statements
      assert_match(/INSERT INTO "solid_queue_jobs".*INSERT INTO "solid_queue_ready_executions"/, statements.find { |sql| sql.start_with?("WITH") })
      assert_no_match(/RETURNING \*|RETURNING [^)]*"arguments"/, statements.find { |sql| sql.start_with?("WITH") })
    else
      assert_operator statements.size, :>, 1
    end
  end

  test "scheduled jobs, and limited jobs whose class doesn't load, are inserted and then dispatched" do
    statements = capturing_statements { AddToBufferJob.set(wait: 1.minute).perform_later(1) }
    assert SolidQueue::Job.last.scheduled?
    assert_no_ready_on_insert statements

    statements = capturing_statements { SolidQueue::Job.create!(queue_name: "default", class_name: "NoSuchJob", arguments: { "arguments" => [] }, concurrency_key: "key", active_job_id: SecureRandom.uuid) }
    assert SolidQueue::Job.last.ready?
    assert_no_ready_on_insert statements
  end

  test "a limited job whose arguments are empty or already record a slot is inserted and then dispatched" do
    lock_key = SolidQueue::Job::ConcurrencyControls::CONCURRENCY_LOCK_KEY
    recorded = { "semaphore_id" => 0, "limit" => 1 }
    [ {}, { "arguments" => [], lock_key => recorded }, { "arguments" => [], lock_key.to_sym => recorded } ].each_with_index do |arguments, i|
      statements = capturing_statements do
        SolidQueue::Job.create!(queue_name: "default", class_name: LimitedJob.name, arguments: arguments, concurrency_key: "key#{i}", active_job_id: SecureRandom.uuid)
      end

      job = SolidQueue::Job.last
      assert job.ready?
      assert_equal SolidQueue::Semaphore.find_by!(key: "key#{i}").id, job.acquired_semaphore_id
      assert_no_ready_on_insert statements
    end
  end

  test "a limited job takes a slot in the statement that inserts it, and records it" do
    job = nil
    statements = capturing_statements { job = LimitedToTwoJob.perform_later("key") }

    solid_queue_job = SolidQueue::Job.find(job.provider_job_id)
    semaphore = SolidQueue::Semaphore.find_by!(key: solid_queue_job.concurrency_key)
    assert solid_queue_job.ready?
    assert_equal 1, semaphore.value
    assert_in_delta LimitedToTwoJob.concurrency_duration.from_now, semaphore.expires_at, 5.seconds
    assert_equal [ semaphore.id, 2 ], [ solid_queue_job.acquired_semaphore_id, solid_queue_job.acquired_concurrency_limit ]

    if postgresql?
      assert_equal [ "WITH" ], verbs(statements), statements
      assert_match(/INSERT INTO "solid_queue_semaphores".*INSERT INTO "solid_queue_jobs".*INSERT INTO "solid_queue_ready_executions".*INSERT INTO "solid_queue_blocked_executions"/,
        statements.find { |sql| sql.start_with?("WITH") })
    end

    semaphore.update_columns(expires_at: 1.hour.ago)
    statements = capturing_statements { job = LimitedToTwoJob.perform_later("key") }
    assert SolidQueue::Job.find(job.provider_job_id).ready?
    assert_equal semaphore.id, SolidQueue::Job.find(job.provider_job_id).acquired_semaphore_id
    assert_equal 0, semaphore.reload.value
    assert_in_delta LimitedToTwoJob.concurrency_duration.from_now, semaphore.expires_at, 5.seconds
    assert_equal [ "WITH" ], verbs(statements), statements if postgresql?

    created = SolidQueue::Job.enqueue(LimitedToTwoJob.new("other"))
    assert_not created.changed?
    assert_equal SolidQueue::Job.find(created.id).arguments, created.arguments
    stored = SolidQueue::Record.connection.select_value("SELECT arguments FROM solid_queue_jobs WHERE id = #{created.id}")
    assert_equal SolidQueue::Job.type_for_attribute(:arguments).serialize(created.arguments), stored
  end

  test "a limited job without a free slot is inserted blocked, and released when the slot is" do
    first, second = LimitedJob.perform_later("key"), nil
    semaphore = SolidQueue::Semaphore.sole
    statements = capturing_statements { second = LimitedJob.perform_later("key") }
    assert_equal semaphore.attributes, semaphore.reload.attributes

    first, second = SolidQueue::Job.find(first.provider_job_id), SolidQueue::Job.find(second.provider_job_id)
    assert first.ready?
    assert second.blocked?
    assert_nil second.acquired_semaphore_id
    assert_in_delta LimitedJob.concurrency_duration.from_now, second.blocked_execution.expires_at, 5.seconds
    assert_equal [ "WITH" ], verbs(statements), statements if postgresql?

    first.unblock_next_blocked_job
    assert second.reload.ready?
    assert_equal SolidQueue::Semaphore.find_by!(key: second.concurrency_key).id, second.acquired_semaphore_id
  end

  test "a limited job enqueued while its slot is being released waits for it, and takes it" do
    skip unless postgresql?

    first = SolidQueue::Job.find(LimitedJob.perform_later("key").provider_job_id)
    signalled, release = Queue.new, Queue.new
    releaser = Thread.new do
      SolidQueue::Record.connection_pool.with_connection do
        SolidQueue::Record.transaction do
          SolidQueue::Semaphore.signal(first)
          signalled << true
          release.pop
        end
      end
    end
    assert signalled.pop(timeout: 5), "the slot wasn't released"

    adder = Thread.new { SolidQueue::Record.connection_pool.with_connection { LimitedJob.perform_later("key").provider_job_id } }
    assert wait_until { backends("wait_event_type = 'Lock' AND query LIKE 'WITH semaphore%'") == 1 }, "the job didn't wait for the release"
    release << true
    releaser.join

    assert SolidQueue::Job.find(adder.value).ready?
    assert_equal 0, SolidQueue::Semaphore.sole.value
  ensure
    release&.push(true)
    releaser&.join
    adder&.join
  end

  test "limited jobs enqueued at once for a new key take exactly the slots there are" do
    skip unless postgresql? # Elsewhere they can deadlock creating the semaphore

    threads, start = 8, Queue.new
    enqueuers = threads.times.map do
      Thread.new { SolidQueue::Record.connection_pool.with_connection { start.pop; LimitedToTwoJob.perform_later("key").provider_job_id } }
    end
    threads.times { start << true }
    jobs = SolidQueue::Job.find(enqueuers.map(&:value))

    assert_equal 2, jobs.count(&:ready?)
    assert_equal threads - 2, jobs.count(&:blocked?)
    assert_equal 0, SolidQueue::Semaphore.sole.value
  end

  test "a job that discards on conflict takes its slot in the statement that inserts it, and isn't inserted without one" do
    ready, discarded, created = nil, nil, nil
    statements = capturing_statements do
      ready = DiscardingJob.perform_later("key")
      discarded = DiscardingJob.new("key").tap(&:enqueue)
      created = SolidQueue::Job.enqueue(DiscardingJob.new("key"))
    end

    assert SolidQueue::Job.find(ready.provider_job_id).ready?
    assert discarded.successfully_enqueued?
    assert_nil discarded.provider_job_id
    assert_not created.persisted?
    assert_equal 1, SolidQueue::Job.count
    assert_equal [ "WITH" ] * 3, verbs(statements), statements if postgresql?

    batch = SolidQueue::Batch.enqueue { DiscardingJob.perform_later("key") }
    assert_equal 1, batch.reload.total_jobs
    assert_equal 1, SolidQueue::Job.count
  end

  test "a capped job that gets a slot, or is blocked, is inserted by one statement after its key is locked" do
    ready, blocked = nil, nil
    statements = [ capturing_statements { ready = CappedJob.perform_later("key") }, capturing_statements { blocked = CappedJob.perform_later("key") } ]

    assert SolidQueue::Job.find(ready.provider_job_id).ready?
    assert SolidQueue::Job.find(blocked.provider_job_id).blocked?
    assert_equal 0, SolidQueue::Semaphore.sole.value
    if postgresql?
      # The check for a full key, then the lock, which creates the semaphore if there's none
      statements.each { |enqueue| assert_equal [ "SELECT", "BEGIN", "INSERT", "WITH", "COMMIT" ], verbs(enqueue), enqueue }
      assert_match(/INSERT INTO "solid_queue_semaphores".*WHERE false/, statements.first.third)
    end
  end

  test "a capped job over max_blocked isn't inserted" do
    2.times { CappedJob.perform_later("key") }

    single, set = CappedJob.new("key"), [ CappedJob.new("key"), CappedJob.new("key") ]
    statements = capturing_statements do
      single.enqueue
      ActiveJob.perform_all_later(set)
    end

    assert single.successfully_enqueued?
    assert_nil single.provider_job_id
    assert_equal [ nil, nil ], set.map(&:successfully_enqueued?)
    assert_equal 2, SolidQueue::Job.count
    # Only the checks for a full key, one for the set
    assert_equal [ "SELECT" ] * 2, verbs(statements) - [ "BEGIN", "COMMIT" ], statements
  end

  test "capped jobs enqueued together are blocked up to max_blocked, and the rest aren't inserted" do
    set = 4.times.map { CappedJob.new("key") }
    statements = capturing_statements { ActiveJob.perform_all_later(set) }

    assert_equal [ true, true, nil, nil ], set.map(&:successfully_enqueued?)
    jobs = SolidQueue::Job.find(set.first(2).map(&:provider_job_id))
    assert jobs.first.ready?
    assert jobs.second.blocked?
    assert_equal 2, SolidQueue::Job.count
    assert_empty statements.grep(/\ADELETE/), statements if postgresql?
  end

  test "a capped job discarded on enqueue is counted into its batch, which mustn't have finished" do
    2.times { CappedJob.perform_later("key") }

    batch = SolidQueue::Batch.enqueue do
      CappedJob.perform_later("key")
      ActiveJob.perform_all_later([ CappedJob.new("key") ])
    end
    assert_equal 2, batch.reload.total_jobs
    assert_equal 2, SolidQueue::Job.count

    SolidQueue::Batch.where(id: batch.id).update_all(finished_at: Time.current)
    assert_raises(SolidQueue::Batch::AlreadyFinished) { CappedJob.new("key").tap { |job| job.batch_id = batch.id }.enqueue }
    assert_raises(SolidQueue::Batch::AlreadyFinished) { ActiveJob.perform_all_later([ CappedJob.new("key").tap { |job| job.batch_id = batch.id } ]) }
  end

  test "a capped job finding max_blocked jobs blocked once its key is locked isn't inserted" do
    2.times { CappedJob.perform_later("key") }
    # As if they were blocked after the check for a full key, and before the lock
    adapter = SolidQueue::Job.database_adapter
    adapter.stubs(:full_with_blocked?).returns(false)

    job, created = CappedJob.new("key"), nil
    statements = capturing_statements do
      job.enqueue
      created = SolidQueue::Job.enqueue(CappedJob.new("key"))
    end

    assert job.successfully_enqueued?
    assert_nil job.provider_job_id
    assert_not created.persisted?
    assert_equal 2, SolidQueue::Job.count
    assert_equal 0, SolidQueue::Semaphore.sole.value
    assert_equal [ "BEGIN", "INSERT", "WITH", "COMMIT" ], verbs(statements).first(4), statements if postgresql?

    # A set taking its slots together
    set = [ CappedJob.new("key"), LimitedJob.new("other") ]
    assert_difference -> { SolidQueue::Job.count }, +1 do
      ActiveJob.perform_all_later(set)
    end
    assert_equal [ nil, true ], set.map(&:successfully_enqueued?)
  ensure
    adapter&.unstub(:full_with_blocked?)
  end

  test "capped jobs enqueued at once, alone and together, on a new key keep max_blocked" do
    skip unless postgresql? # Elsewhere they can deadlock creating the semaphore

    threads, start = 12, Queue.new
    enqueuers = threads.times.map do |thread|
      Thread.new do
        SolidQueue::Record.connection_pool.with_connection do
          start.pop
          thread.even? ? 10.times { CappedJob.perform_later("key") } : 4.times { ActiveJob.perform_all_later(3.times.map { CappedJob.new("key") }) }
        end
      end
    end
    threads.times { start << true }
    enqueuers.each(&:join)

    assert_equal [ 1, 1 ], [ SolidQueue::ReadyExecution.count, SolidQueue::BlockedExecution.count ]
    assert_equal 2, SolidQueue::Job.count
    assert_equal 0, SolidQueue::Semaphore.sole.value
  end

  test "limited jobs in a batch are counted, tracked, and made ready or blocked by the same statement" do
    batch = nil
    statements = capturing_statements { batch = SolidQueue::Batch.enqueue { 2.times { LimitedJob.perform_later("key") } } }

    first, second = SolidQueue::Job.order(:id).to_a
    if postgresql?
      enqueues = statements.select { |sql| sql.include?('INSERT INTO "solid_queue_jobs"') }
      assert_equal 2, enqueues.size, statements
      assert enqueues.all? { |sql| sql.match?(/\AWITH batch AS .*UPDATE "solid_queue_batches".*INSERT INTO "solid_queue_semaphores"/) }, enqueues
    end
    assert first.ready?
    assert second.blocked?
    assert_equal [ batch.id ] * 2, [ first, second ].map { |job| job.batch_execution.batch_id }
    assert_equal 2, batch.reload.total_jobs
    assert_equal 0, SolidQueue::Semaphore.sole.value
  end

  test "a limited job added to a finished batch takes no slot" do
    batch = SolidQueue::Batch.enqueue { AddToBufferJob.perform_later(1) }
    SolidQueue::Batch.where(id: batch.id).update_all(finished_at: Time.current)
    late_job = LimitedJob.new("key").tap { |job| job.batch_id = batch.id }

    assert_raises(SolidQueue::Batch::AlreadyFinished) { late_job.enqueue }
    assert_equal 0, SolidQueue::Semaphore.count
    assert_equal 0, SolidQueue::BlockedExecution.count
  end

  test "a job in a batch is counted, tracked and made ready by the same statement" do
    batch = nil
    statements = capturing_statements { batch = SolidQueue::Batch.enqueue { AddToBufferJob.perform_later(1) } }

    job = SolidQueue::Job.last
    assert job.ready?
    assert_equal batch.id, job.batch_execution.batch_id
    assert_equal 1, batch.reload.total_jobs

    if postgresql?
      assert_match(/UPDATE "solid_queue_batches" SET total_jobs.*INSERT INTO "solid_queue_jobs".*INSERT INTO "solid_queue_ready_executions".*INSERT INTO "solid_queue_batch_executions"/,
        statements.find { |sql| sql.start_with?("WITH") })
      assert statements.none? { |sql| sql.match?(/\AUPDATE "solid_queue_batches" SET total_jobs|\AINSERT INTO "solid_queue_(ready|batch)_executions"/) }, statements
    else
      assert_no_ready_on_insert statements
    end
  end

  test "a retry rejoining its batch on its own is one statement and isn't counted again" do
    batch = SolidQueue::Batch.enqueue { AddToBufferJob.perform_later(1) }
    retry_job = AddToBufferJob.new(2).tap { |job| job.batch_id, job.executions = batch.id, 1 }

    statements = capturing_statements { retry_job.enqueue }

    assert retry_job.successfully_enqueued?
    assert SolidQueue::Job.find(retry_job.provider_job_id).batch_execution.present?
    assert_equal 1, batch.reload.total_jobs
    assert_equal [ "WITH" ], verbs(statements), statements if postgresql?
  end

  test "a job added to a finished batch raises and leaves nothing behind" do
    batch = SolidQueue::Batch.enqueue { AddToBufferJob.perform_later(1) }
    SolidQueue::Batch.where(id: batch.id).update_all(finished_at: Time.current)
    late_job = AddToBufferJob.new(2).tap { |job| job.batch_id = batch.id }

    statements = capturing_statements do
      assert_raises(SolidQueue::Batch::AlreadyFinished) { late_job.enqueue }
    end

    assert_equal 1, SolidQueue::Job.count
    assert_equal 1, SolidQueue::ReadyExecution.count
    assert_equal 1, SolidQueue::BatchExecution.count
    assert_equal 1, batch.reload.total_jobs
    assert_equal [ "WITH" ], verbs(statements), statements if postgresql?

    SolidQueue::Job.transaction do
      assert_raises(SolidQueue::Batch::AlreadyFinished) { late_job.enqueue }
      # Before anything is rolled back. The existing path inserts the job before it raises.
      assert_equal 1, SolidQueue::Job.count if postgresql?
      raise ActiveRecord::Rollback
    end
  end

  test "enqueued inside a transaction, the job and its ready execution go with it" do
    skip unless postgresql?

    statements = capturing_statements do
      SolidQueue::Job.transaction do
        AddToBufferJob.perform_later(1)
        raise ActiveRecord::Rollback
      end
    end

    assert_equal 3, statements.size, statements
    assert_match(/\ABEGIN/, statements.first)
    assert_match(/\AROLLBACK/, statements.last)
    assert_equal 0, SolidQueue::Job.count
    assert_equal 0, SolidQueue::ReadyExecution.count
  end

  test "a failed insert leaves neither the job nor its ready execution" do
    skip unless postgresql?

    SolidQueue::ReadyExecution.connection.execute("ALTER TABLE solid_queue_ready_executions ADD CONSTRAINT refuse_queue CHECK (queue_name <> 'refused')")
    error = assert_raises(SolidQueue::Job::EnqueueError) { AddToBufferJob.set(queue: "refused").perform_later(1) }

    assert_match(/CheckViolation/, error.message)
    assert_equal 0, SolidQueue::Job.count
  ensure
    SolidQueue::ReadyExecution.connection.execute("ALTER TABLE solid_queue_ready_executions DROP CONSTRAINT IF EXISTS refuse_queue") if postgresql?
  end

  test "before callbacks run, and what they change is inserted" do
    with_job_callback(:reroute, -> { self.queue_name = "rerouted" }, :before_create) do
      statements = capturing_statements { AddToBufferJob.perform_later(1) }

      assert_equal "rerouted", SolidQueue::Job.last.ready_execution.queue_name
      assert_equal [ "WITH" ], verbs(statements), statements if postgresql?
    end
  end

  test "a failing validation inserts nothing" do
    with_job_callback(:refuse, -> { errors.add(:base, "refused") }, :validate) do
      statements = capturing_statements do
        assert_raises(SolidQueue::Job::EnqueueError) { AddToBufferJob.perform_later(1) }
      end

      assert_empty statements
      assert_equal 0, SolidQueue::Job.count
    end
  end

  test "after_commit callbacks run once the job is committed" do
    committed, elsewhere = [], method(:elsewhere)
    with_job_callback(:record_commit, -> { committed << [ id, previously_new_record?, elsewhere.call { SolidQueue::Job.exists?(id) } ] }, :after_commit, on: :create) do
      job = nil
      statements = capturing_statements { job = AddToBufferJob.perform_later(1) }

      assert_equal [ [ job.provider_job_id, true, true ] ], committed
      assert_equal [ "WITH" ], verbs(statements) - [ "SELECT" ], statements if postgresql?
    end
  end

  test "with an after_create callback, the insert and the callback share a transaction" do
    created, elsewhere = [], method(:elsewhere)
    with_job_callback(:record_create, -> { created << [ id, elsewhere.call { SolidQueue::Job.exists?(id) } ] }, :after_create) do
      job = nil
      statements = capturing_statements { job = AddToBufferJob.perform_later(1) }

      assert_equal [ [ job.provider_job_id, false ] ], created
      assert SolidQueue::Job.find(job.provider_job_id).ready?
      if postgresql?
        assert_equal [ "BEGIN", "WITH", "COMMIT" ], verbs(statements) - [ "SELECT" ], statements
      end
    end
  end

  test "an after_create callback that fails rolls back the job and its ready execution" do
    with_job_callback(:fail_after_create, -> { raise ActiveRecord::ActiveRecordError, "after_create failed" }, :after_create) do
      assert_raises(SolidQueue::Job::EnqueueError) { AddToBufferJob.perform_later(1) }
    end

    assert_equal 0, SolidQueue::Job.count
    assert_equal 0, SolidQueue::ReadyExecution.count
  end

  test "a before callback that runs a query begins the transaction, and the insert joins it" do
    skip unless postgresql?

    with_job_callback(:look_first, -> { SolidQueue::Job.exists? }, :before_create) do
      statements = capturing_statements { AddToBufferJob.perform_later(1) }

      assert_equal [ "BEGIN", "SELECT", "WITH", "COMMIT" ], verbs(statements), statements
    end
  end

  test "a before callback that schedules the job leaves it scheduled" do
    with_job_callback(:postpone, -> { self.scheduled_at = 1.hour.from_now }, :before_create) do
      statements = capturing_statements { AddToBufferJob.perform_later(1) }

      assert SolidQueue::Job.last.scheduled?
      assert_no_ready_on_insert statements
    end
  end

  test "a job added while its batch finishes is not inserted" do
    skip unless postgresql?

    batch = SolidQueue::Batch.enqueue { AddToBufferJob.perform_later(1) }
    locked, finish = Queue.new, Queue.new
    finisher = Thread.new do
      SolidQueue::Record.connection_pool.with_connection do
        SolidQueue::Batch.transaction do
          SolidQueue::Batch.lock.find(batch.id)
          locked << true
          finish.pop
          SolidQueue::Batch.where(id: batch.id).update_all(finished_at: Time.current)
        end
      end
    end
    assert locked.pop(timeout: 5), "the batch wasn't locked"

    late_job = AddToBufferJob.new(2).tap { |job| job.batch_id = batch.id }
    adder = Thread.new do
      SolidQueue::Record.connection_pool.with_connection { late_job.enqueue }
    rescue => error
      error
    end
    assert wait_until { backends("wait_event_type = 'Lock' AND query LIKE 'WITH batch%'") == 1 }, "the job wasn't added while the batch finished"
    finish << true
    finisher.join

    assert_kind_of SolidQueue::Batch::AlreadyFinished, adder.value
    assert_equal 1, SolidQueue::Job.count
    assert_equal 1, batch.reload.total_jobs
  ensure
    finish&.push(true)
    finisher&.join
    adder&.join
  end

  test "while writes are prevented, nothing is inserted" do
    ActiveRecord::Base.while_preventing_writes do
      assert_raises(SolidQueue::Job::EnqueueError) { AddToBufferJob.perform_later(1) }
    end

    assert_equal 0, SolidQueue::Job.count
  end

  test "without INSERT ... RETURNING, the job is inserted and then made ready" do
    skip unless postgresql?

    ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.any_instance.stubs(:use_insert_returning?).returns(false)
    statements = capturing_statements { AddToBufferJob.perform_later(1) }

    assert SolidQueue::Job.last.ready?
    assert_no_ready_on_insert statements
  end

  test "a save that fails after the insert leaves the next save of the job to dispatch it" do
    job = SolidQueue::Job.new(queue_name: "default", class_name: "AddToBufferJob", arguments: { "arguments" => [ 1 ] }, active_job_id: SecureRandom.uuid, scheduled_at: Time.current)
    with_job_callback(:fail_after_insert, proc { |&insert| insert.call; raise ActiveRecord::ActiveRecordError, "failed after insert" }, :around_create) do
      assert_raises(ActiveRecord::ActiveRecordError) { job.save! }
    end

    job.scheduled_at = 1.hour.from_now
    job.save!
    assert job.reload.scheduled?
  end

  test "enqueued from a thread without a connection, the job is still inserted in one statement" do
    statements = Thread.new do
      pool = SolidQueue::Record.connection_pool
      assert_nil pool.active_connection?
      capturing_statements { AddToBufferJob.perform_later(1) }
    ensure
      pool.release_connection
    end.value

    assert SolidQueue::Job.last.ready?
    assert_equal [ "WITH" ], verbs(statements), statements if postgresql?
  end

  test "an enqueue interrupted, or whose thread is killed, while its statement waits on a lock leaves no job" do
    skip unless postgresql?

    stop = Class.new(Exception)
    { "interrupted" => ->(thread) { thread.raise(stop) }, "killed" => ->(thread) { thread.kill } }.each do |how, interrupt|
      begin
        locked, release = Queue.new, Queue.new
        locker = Thread.new do
          SolidQueue::Record.connection_pool.with_connection do |connection|
            connection.transaction do
              connection.execute("LOCK TABLE solid_queue_jobs IN SHARE MODE")
              locked << true
              release.pop
            end
          end
        end
        locked.pop

        enqueuer = Thread.new do
          SolidQueue::Record.connection_pool.with_connection do
            AddToBufferJob.perform_later(1)
          rescue stop
            SolidQueue::Job.count # The interrupted connection still works
          end
        end

        assert wait_until { backends("wait_event_type = 'Lock' AND query LIKE 'WITH job%'") == 1 }, "#{how}: the enqueue didn't wait on the lock"
        interrupt.call(enqueuer)
        assert enqueuer.join(5), "#{how}: the statement went on waiting"
        assert_equal 0, enqueuer.value if how == "interrupted"

        release << true
        locker.join
        assert wait_until { backends("state = 'active' AND query LIKE 'WITH job%'").zero? }
        assert_equal 0, SolidQueue::Record.uncached { SolidQueue::Job.count }, how
      ensure
        release&.push(true)
        locker&.join
        enqueuer&.join
      end
    end
  end

  test "with a transaction isolation level set, the statement runs in a transaction at that level" do
    skip unless postgresql? && SolidQueue::Record.respond_to?(:with_pool_transaction_isolation_level)

    statements = SolidQueue::Record.with_pool_transaction_isolation_level(:serializable) do
      capturing_statements { AddToBufferJob.perform_later(1) }
    end

    assert_equal [ "BEGIN", "WITH", "COMMIT" ], verbs(statements), statements
    assert_match(/SERIALIZABLE/, statements.first)
    assert SolidQueue::Job.last.ready?
  end

  test "on a connection the server has closed, the enqueue reconnects and succeeds" do
    skip unless postgresql?

    SolidQueue::Job.count
    pid = SolidQueue::Record.connection.select_value("SELECT pg_backend_pid()")
    elsewhere { SolidQueue::Record.connection.select_value("SELECT pg_terminate_backend(#{pid})") }
    assert wait_until { elsewhere { SolidQueue::Record.connection.select_value("SELECT count(*) FROM pg_stat_activity WHERE pid = #{pid}") }.zero? }

    job = AddToBufferJob.perform_later(1)

    assert job.successfully_enqueued?
    assert SolidQueue::Job.find(job.provider_job_id).ready?
  end

  test "a query cached before the enqueue isn't served after it" do
    SolidQueue::Record.cache do
      before = SolidQueue::Job.count
      AddToBufferJob.perform_later(1)

      assert_equal before + 1, SolidQueue::Job.count
    end
  end

  test "with a before_commit callback, the insert runs in a transaction and the callback runs before its commit" do
    called, elsewhere = [], method(:elsewhere)
    with_job_callback(:record_before_commit, -> { called << elsewhere.call { SolidQueue::Job.exists?(id) } }, :before_commit) do
      statements = capturing_statements { AddToBufferJob.perform_later(1) }

      assert_equal [ false ], called
      assert_equal [ "BEGIN", "WITH", "COMMIT" ], verbs(statements) - [ "SELECT" ], statements if postgresql?
    end
  end

  private
    def postgresql?
      SolidQueue::Record.connection.adapter_name == "PostgreSQL"
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

    def assert_no_ready_on_insert(statements)
      assert statements.none? { |sql| sql.start_with?("WITH") }, statements
    end

    def with_job_callback(name, body, macro, **options)
      SolidQueue::Job.define_method(name, &body)
      SolidQueue::Job.public_send(macro, name, **options)
      yield
    ensure
      kind = { before_create: [ :create, :before ], after_create: [ :create, :after ], around_create: [ :create, :around ], after_commit: [ :commit, :after ], before_commit: [ :before_commit, :before ], validate: [ :validate ] }.fetch(macro)
      SolidQueue::Job.skip_callback(*kind, name)
      SolidQueue::Job.remove_method(name)
    end

    def wait_until(timeout: 5)
      deadline = Time.now + timeout
      sleep 0.01 until (met = yield) || Time.now > deadline
      met
    end

    def backends(condition)
      SolidQueue::Record.uncached { SolidQueue::Record.connection.select_value("SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid() AND #{condition}") }
    end

    def elsewhere(&block)
      Thread.new { SolidQueue::Record.connection_pool.with_connection(&block) }.value
    end
end
