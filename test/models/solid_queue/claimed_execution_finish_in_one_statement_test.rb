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
      assert_equal [ "WITH" ], verbs(statements), statements
      assert_match(/DELETE FROM "solid_queue_claimed_executions".*UPDATE "solid_queue_jobs"/, statements.first)
    else
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
    assert_equal "WITH", verbs(statements).first, statements if postgresql?
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

  test "a job in a batch, one not kept once finished, and one whose update runs a callback finish as before" do
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

    updated = []
    with_job_callback(:record_update, -> { updated << id }, :after_update) do
      claimed_execution = claim(AddToBufferJob.perform_later(3))
      assert_finished_as_before(claimed_execution)
      assert_equal [ claimed_execution.job_id ], updated
    end
  end

  test "a job whose cached association has changes to save finishes as before" do
    claimed_execution = claim(AddToBufferJob.perform_later(1))
    claimed_execution.job.build_ready_execution(queue_name: "background", priority: 0)

    assert_no_one_statement_finish { claimed_execution.perform }
    assert SolidQueue::Job.find(claimed_execution.job_id).finished?
    assert SolidQueue::ReadyExecution.exists?(job_id: claimed_execution.job_id)
  end

  test "inside a transaction, the statement runs in it" do
    claimed_execution = claim(AddToBufferJob.perform_later(1))

    statements = capturing_statements do
      SolidQueue::Record.transaction do
        claimed_execution.perform
        raise ActiveRecord::Rollback
      end
    end

    assert SolidQueue::ClaimedExecution.exists?(claimed_execution.id)
    assert_not SolidQueue::Job.find(claimed_execution.job_id).finished?
    assert_equal [ "BEGIN", "WITH", "ROLLBACK" ], verbs(statements), statements if postgresql?
  end

  test "on a connection the server has closed, the statement runs in a transaction, which reconnects" do
    skip unless postgresql?

    claimed_execution = claim(AddToBufferJob.perform_later(1))
    pid = SolidQueue::Record.connection.select_value("SELECT pg_backend_pid()")
    elsewhere { SolidQueue::Record.connection.select_value("SELECT pg_terminate_backend(#{pid})") }
    assert wait_until { elsewhere { SolidQueue::Record.connection.select_value("SELECT count(*) FROM pg_stat_activity WHERE pid = #{pid}") }.zero? }

    statements = capturing_statements { claimed_execution.perform }

    assert SolidQueue::Job.find(claimed_execution.job_id).finished?
    assert_equal [ "BEGIN", "WITH", "COMMIT" ], verbs(statements), statements
  end

  test "a statement that fails leaves the claim, and raises FinalizationError" do
    claimed_execution = claim(AddToBufferJob.perform_later(1))
    SolidQueue::Record.connection.stubs(:exec_update).raises(ActiveRecord::StatementInvalid.new("transient DB glitch"))

    assert_raises(SolidQueue::ClaimedExecution::FinalizationError) { claimed_execution.perform }

    SolidQueue::Record.connection.unstub(:exec_update)
    assert SolidQueue::ClaimedExecution.exists?(claimed_execution.id)
    assert_not SolidQueue::Job.find(claimed_execution.job_id).finished?
  end

  test "a finish interrupted, or whose thread is killed, while its statement waits on a lock leaves the job unfinished" do
    skip unless postgresql?

    stop = Class.new(Exception)
    { "interrupted" => ->(thread) { thread.raise(stop) }, "killed" => ->(thread) { thread.kill } }.each do |how, interrupt|
      begin
        claimed_execution = claim(AddToBufferJob.perform_later(how))
        locked, release = Queue.new, Queue.new
        locker = Thread.new do
          SolidQueue::Record.connection_pool.with_connection do |connection|
            connection.transaction do
              connection.execute("SELECT 1 FROM solid_queue_claimed_executions WHERE id = #{claimed_execution.id} FOR UPDATE")
              locked << true
              release.pop
            end
          end
        end
        locked.pop

        finisher = Thread.new do
          SolidQueue::Record.connection_pool.with_connection do
            claimed_execution.perform
          rescue stop
            SolidQueue::Job.count # The interrupted connection still works
          end
        end

        assert wait_until { backends("wait_event_type = 'Lock' AND query LIKE 'WITH claim%'") == 1 }, "#{how}: the finish didn't wait on the lock"
        interrupt.call(finisher)
        assert finisher.join(5), "#{how}: the statement went on waiting"
        assert_kind_of Integer, finisher.value if how == "interrupted"

        release << true
        locker.join
        assert wait_until { backends("state = 'active' AND query LIKE 'WITH claim%'").zero? }
        assert SolidQueue::ClaimedExecution.exists?(claimed_execution.id), how
        assert_not SolidQueue::Record.uncached { SolidQueue::Job.find(claimed_execution.job_id).finished? }, how
      ensure
        release&.push(true)
        locker&.join
        finisher&.join
      end
    end
  end

  test "a query cached before the finish isn't served after it" do
    claimed_execution = claim(AddToBufferJob.perform_later(1))

    SolidQueue::Record.cache do
      assert_equal 0, SolidQueue::Job.finished.count
      claimed_execution.perform

      assert_equal 1, SolidQueue::Job.finished.count
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
      assert_includes verbs(statements), "BEGIN" if postgresql?
    end

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

    def with_job_callback(name, body, macro)
      SolidQueue::Job.define_method(name, &body)
      SolidQueue::Job.public_send(macro, name)
      yield
    ensure
      SolidQueue::Job.skip_callback(:update, :after, name)
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
