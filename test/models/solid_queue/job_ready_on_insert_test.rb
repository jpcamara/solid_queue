require "test_helper"

class SolidQueue::JobReadyOnInsertTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class LimitedJob < ApplicationJob
    limits_concurrency key: ->(value) { value }

    def perform(value)
    end
  end

  setup do
    skip "Needs Active Record 8 or later" if ActiveRecord.version < Gem::Version.new("8.0")
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
    else
      assert_operator statements.size, :>, 1
    end
  end

  test "scheduled and concurrency limited jobs are inserted and then dispatched" do
    statements = capturing_statements { AddToBufferJob.set(wait: 1.minute).perform_later(1) }
    assert SolidQueue::Job.last.scheduled?
    assert_no_ready_on_insert statements

    statements = capturing_statements { LimitedJob.perform_later("key") }
    assert SolidQueue::Job.last.ready?
    assert_no_ready_on_insert statements
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

    assert_raises(SolidQueue::Batch::AlreadyFinished) do
      SolidQueue::Job.transaction { late_job.enqueue }
    end
    assert_equal 1, SolidQueue::Job.count
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
    locked.pop

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

  test "an enqueue interrupted while its statement waits on a lock leaves no job" do
    skip unless postgresql?

    stop = Class.new(Exception)
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

    assert wait_until { backends("wait_event_type = 'Lock'") == 1 }, "the enqueue didn't wait on the lock"
    enqueuer.raise(stop)
    assert enqueuer.join(5), "the interrupted statement went on waiting"
    assert_equal 0, enqueuer.value

    release << true
    locker.join
    assert wait_until { backends("state = 'active' AND query LIKE 'WITH job%'").zero? }
    assert_equal 0, SolidQueue::Record.uncached { SolidQueue::Job.count }
  ensure
    release&.push(true)
    locker&.join
    enqueuer&.join
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
      kind = { before_create: [ :create, :before ], after_create: [ :create, :after ], around_create: [ :create, :around ], after_commit: [ :commit, :after ], validate: [ :validate ] }.fetch(macro)
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
