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
      assert_equal on_its_own, verbs(statements), statements
      assert_match(/INSERT INTO "solid_queue_jobs".*INSERT INTO "solid_queue_ready_executions"/, statements.find { |sql| sql.start_with?("WITH") })
    else
      assert_operator statements.size, :>, 1
    end
  end

  test "scheduled jobs, and limited jobs that discard on conflict or whose class doesn't load, are inserted and then dispatched" do
    statements = capturing_statements { AddToBufferJob.set(wait: 1.minute).perform_later(1) }
    assert SolidQueue::Job.last.scheduled?
    assert_no_ready_on_insert statements

    statements = capturing_statements { DiscardingJob.perform_later("key") }
    assert SolidQueue::Job.last.ready?
    assert_no_ready_on_insert statements

    statements = capturing_statements { SolidQueue::Job.create!(queue_name: "default", class_name: "NoSuchJob", arguments: {}, concurrency_key: "key", active_job_id: SecureRandom.uuid) }
    assert SolidQueue::Job.last.ready?
    assert_no_ready_on_insert statements
  end

  test "a limited job takes a slot in the statement that inserts it, and records it" do
    job = nil
    statements = capturing_statements { job = LimitedToTwoJob.perform_later("key") }

    solid_queue_job = SolidQueue::Job.find(job.provider_job_id)
    semaphore = SolidQueue::Semaphore.find_by!(key: solid_queue_job.concurrency_key)
    assert solid_queue_job.ready?
    assert_equal 1, semaphore.value
    assert_equal [ semaphore.id, 2 ], [ solid_queue_job.acquired_semaphore_id, solid_queue_job.acquired_concurrency_limit ]

    if postgresql?
      assert_equal on_its_own, verbs(statements), statements
      assert_match(/INSERT INTO "solid_queue_semaphores".*INSERT INTO "solid_queue_jobs".*INSERT INTO "solid_queue_ready_executions".*INSERT INTO "solid_queue_blocked_executions"/,
        statements.find { |sql| sql.start_with?("WITH") })
    end

    statements = capturing_statements { job = LimitedToTwoJob.perform_later("key") }
    assert SolidQueue::Job.find(job.provider_job_id).ready?
    assert_equal semaphore.id, SolidQueue::Job.find(job.provider_job_id).acquired_semaphore_id
    assert_equal 0, semaphore.reload.value
    assert_equal on_its_own, verbs(statements), statements if postgresql?

    created = SolidQueue::Job.enqueue(LimitedToTwoJob.new("other"))
    assert_not created.changed?
    assert_equal SolidQueue::Job.find(created.id).arguments, created.arguments
  end

  test "a limited job without a free slot is inserted blocked, and released when the slot is" do
    first, second = LimitedJob.perform_later("key"), nil
    statements = capturing_statements { second = LimitedJob.perform_later("key") }

    first, second = SolidQueue::Job.find(first.provider_job_id), SolidQueue::Job.find(second.provider_job_id)
    assert first.ready?
    assert second.blocked?
    assert_nil second.acquired_semaphore_id
    assert_in_delta LimitedJob.concurrency_duration.from_now, second.blocked_execution.expires_at, 5.seconds
    assert_equal on_its_own, verbs(statements), statements if postgresql?

    first.unblock_next_blocked_job
    assert second.reload.ready?
    assert_equal SolidQueue::Semaphore.find_by!(key: second.concurrency_key).id, second.acquired_semaphore_id
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
    assert_equal on_its_own, verbs(statements), statements if postgresql?
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
    assert_equal on_its_own.map { |verb| verb == "COMMIT" ? "ROLLBACK" : verb }, verbs(statements), statements if postgresql?

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
      assert_equal on_its_own, verbs(statements), statements if postgresql?
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
      assert_equal on_its_own, verbs(statements) - [ "SELECT" ], statements if postgresql?
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

  private
    def postgresql?
      SolidQueue::Record.connection.adapter_name == "PostgreSQL"
    end

    # Rails 7.1 begins the save's transaction for any statement with binds
    def on_its_own
      ActiveRecord.version >= Gem::Version.new("7.2") ? [ "WITH" ] : [ "BEGIN", "WITH", "COMMIT" ]
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
      assert statements.none? { |sql| sql.start_with?("WITH job AS") }, statements
    end

    def with_job_callback(name, body, macro, **options)
      SolidQueue::Job.define_method(name, &body)
      SolidQueue::Job.public_send(macro, name, **options)
      yield
    ensure
      kind = { before_create: [ :create, :before ], after_create: [ :create, :after ], after_commit: [ :commit, :after ], validate: [ :validate ] }.fetch(macro)
      SolidQueue::Job.skip_callback(*kind, name)
      SolidQueue::Job.remove_method(name)
    end

    def elsewhere(&block)
      Thread.new { SolidQueue::Record.connection_pool.with_connection(&block) }.value
    end
end
