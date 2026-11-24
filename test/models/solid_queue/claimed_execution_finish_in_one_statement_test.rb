require "test_helper"

class SolidQueue::ClaimedExecutionFinishInOneStatementTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class LimitedJob < ApplicationJob
    limits_concurrency key: ->(value) { value }

    def perform(value)
    end
  end

  setup do
    skip "Needs Active Record 8 or later" if ActiveRecord.version < Gem::Version.new("8.0")

    @process = SolidQueue::Process.register(kind: "Worker", pid: 42, name: "worker-123", metadata: { queue: "background" })
  end

  teardown do
    SolidQueue::Batch.destroy_all
    SolidQueue::Process.destroy_all
  end

  test "a job that ran is finished, and its claim deleted, in one statement" do
    claimed_execution = claim(AddToBufferJob.perform_later(1))
    job = claimed_execution.job

    statements = capturing_statements { claimed_execution.perform }

    assert_equal [ 1 ], JobBuffer.values
    assert_not SolidQueue::ClaimedExecution.exists?(claimed_execution.id)
    assert job.finished?
    assert_not job.changed?
    assert_equal [ job.finished_at, job.updated_at ], SolidQueue::Job.find(job.id).values_at(:finished_at, :updated_at)

    if postgresql?
      assert_equal finish_verbs, verbs(statements), statements
      assert_match(/DELETE FROM "solid_queue_claimed_executions".*UPDATE "solid_queue_jobs"/, statements.grep(/\AWITH/).sole)
    else
      assert statements.none? { |sql| sql.start_with?("WITH") }, statements
      assert_operator statements.size, :>, 1
    end
  end

  test "a job whose claim is gone when it finishes is left unfinished" do
    claimed_execution = claim(AddToBufferJob.perform_later(1))
    elsewhere { SolidQueue::ClaimedExecution.where(id: claimed_execution.id).delete_all }

    claimed_execution.perform

    assert_equal [ 1 ], JobBuffer.values
    assert_not SolidQueue::Job.find(claimed_execution.job_id).finished?
  end

  test "a limited job releases its lock after the statement, and the next job is unblocked" do
    first = claim(LimitedJob.perform_later("key"))
    second = SolidQueue::Job.find_by!(active_job_id: LimitedJob.perform_later("key").job_id)
    assert second.blocked?

    statements = capturing_statements { first.perform }

    assert SolidQueue::Job.find(first.job_id).finished?
    assert second.reload.ready?
    assert_equal 0, SolidQueue::Semaphore.find_by!(key: second.concurrency_key).value
    assert_equal finish_verbs, verbs(statements).first(finish_verbs.size), statements if postgresql?
  end

  test "a job left unfinished because its claim is gone doesn't release its lock" do
    first = claim(LimitedJob.perform_later("key"))
    second = SolidQueue::Job.find_by!(active_job_id: LimitedJob.perform_later("key").job_id)
    elsewhere { SolidQueue::ClaimedExecution.where(id: first.id).delete_all }

    first.perform

    assert_not SolidQueue::Job.find(first.job_id).finished?
    assert second.reload.blocked?
    assert_equal 0, SolidQueue::Semaphore.find_by!(key: second.concurrency_key).value
  end

  test "a job in a batch, and one not kept once finished, finish as before" do
    batch = SolidQueue::Batch.enqueue { AddToBufferJob.perform_later(1) }
    claimed_execution = claim_job(batch.jobs.first)
    assert_finished_as_before(claimed_execution)
    assert_not SolidQueue::BatchExecution.exists?(job_id: claimed_execution.job_id)

    begin
      SolidQueue.preserve_finished_jobs = false
      claimed_execution = claim(AddToBufferJob.perform_later(2))
      assert_no_one_statement_finish { claimed_execution.perform }
      assert_not SolidQueue::Job.exists?(claimed_execution.job_id)
    ensure
      SolidQueue.preserve_finished_jobs = true
    end
  end

  test "while writes are prevented, the job finishes as before, and fails to" do
    claimed_execution = claim(AddToBufferJob.perform_later(1))

    statements = capturing_statements do
      assert_raises(SolidQueue::ClaimedExecution::FinalizationError) do
        SolidQueue::Record.while_preventing_writes { claimed_execution.perform }
      end
    end

    assert statements.none? { |sql| sql.start_with?("WITH") }, statements
    assert SolidQueue::ClaimedExecution.exists?(claimed_execution.id)
    assert_not SolidQueue::Job.find(claimed_execution.job_id).finished?
  end

  test "inside a transaction, the job finishes as before" do
    claimed_execution = claim(AddToBufferJob.perform_later(1))

    SolidQueue::Record.transaction do
      assert_no_one_statement_finish { claimed_execution.perform }
      raise ActiveRecord::Rollback
    end

    assert SolidQueue::ClaimedExecution.exists?(claimed_execution.id)
    assert_not SolidQueue::Job.find(claimed_execution.job_id).finished?
    assert claimed_execution.job.changed?
  end

  test "a job with changes to save finishes as before, saving them" do
    claimed_execution = claim(AddToBufferJob.perform_later(1))
    claimed_execution.job.arguments["exception_executions"] = { "[RuntimeError]" => 1 }

    assert_no_one_statement_finish { claimed_execution.perform }

    job = SolidQueue::Job.find(claimed_execution.job_id)
    assert job.finished?
    assert_equal({ "[RuntimeError]" => 1 }, job.arguments["exception_executions"])
  end

  test "without automatic timestamps, updated_at is left alone" do
    claimed_execution = claim(AddToBufferJob.perform_later(1))
    updated_at = claimed_execution.job.updated_at

    begin
      SolidQueue::Job.record_timestamps = false
      statements = capturing_statements { claimed_execution.perform }
    ensure
      SolidQueue::Job.record_timestamps = true
    end

    job = SolidQueue::Job.find(claimed_execution.job_id)
    assert job.finished?
    assert_equal updated_at, job.updated_at
    assert_equal finish_verbs, verbs(statements), statements if postgresql?
  end

  test "a statement that fails leaves the claim, and raises FinalizationError" do
    claimed_execution = claim(AddToBufferJob.perform_later(1))
    skip unless postgresql?
    SolidQueue::Record.database_adapter.stubs(:finish_sql).returns("UPDATE solid_queue_jobs SET missing_column = $2 WHERE id = $1 RETURNING id")

    error = assert_raises(SolidQueue::ClaimedExecution::FinalizationError) { claimed_execution.perform }
    assert_kind_of ActiveRecord::StatementInvalid, error.cause

    assert SolidQueue::ClaimedExecution.exists?(claimed_execution.id)
    assert_not SolidQueue::Job.find(claimed_execution.job_id).finished?
  end

  test "a query cached before the finish isn't served after it" do
    claimed_execution = claim(AddToBufferJob.perform_later(1))

    SolidQueue::Record.cache do
      assert_equal 0, SolidQueue::Job.finished.count
      claimed_execution.perform

      assert_equal 1, SolidQueue::Job.finished.count
    end
  end

  test "the statement is prepared" do
    skip "Needs prepared statements" unless postgresql? && SolidQueue::Record.connection.prepared_statements

    SolidQueue::Record.connection_pool.with_connection do |connection|
      prepared = -> { connection.select_value("SELECT count(*) FROM pg_prepared_statements WHERE statement LIKE 'WITH claim AS%'") }
      2.times { AddToBufferJob.perform_later(1) }
      claimed = SolidQueue::ReadyExecution.claim("background", 2, 42)

      claimed.first.perform
      before = prepared.()
      claimed.second.perform

      assert_operator before, :>=, 1
      assert_equal before, prepared.()
    end
  end

  private
    def claim(active_job)
      claim_job(SolidQueue::Job.find_by!(active_job_id: active_job.job_id))
    end

    def claim_job(job)
      SolidQueue::ReadyExecution.claim(job.queue_name, 1, @process.id)
      SolidQueue::ClaimedExecution.find_by!(job_id: job.id).tap(&:job)
    end

    def assert_finished_as_before(claimed_execution)
      assert_no_one_statement_finish { claimed_execution.perform }
      assert_not SolidQueue::ClaimedExecution.exists?(claimed_execution.id)
      assert SolidQueue::Job.find(claimed_execution.job_id).finished?
    end

    def assert_no_one_statement_finish(&block)
      statements = capturing_statements(&block)
      assert statements.none? { |sql| sql.start_with?("WITH") }, statements
    end

    def postgresql?
      SolidQueue::Record.connection.adapter_name == "PostgreSQL"
    end

    def finish_verbs
      if PG.library_version >= 18_00_00 && Gem::Version.new(PG::VERSION) < Gem::Version.new("1.6.0")
        [ "BEGIN", "WITH", "COMMIT" ]
      else
        [ "WITH" ]
      end
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

    def elsewhere(&block)
      Thread.new { SolidQueue::Record.connection_pool.with_connection(&block) }.value
    end
end
