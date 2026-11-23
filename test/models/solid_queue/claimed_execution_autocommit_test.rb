require "test_helper"

class SolidQueue::ClaimedExecutionAutocommitTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  Interrupted = Class.new(Exception)

  setup do
    skip unless ActiveRecord.version >= Gem::Version.new("8.0") && SolidQueue::Record.connection.adapter_name == "PostgreSQL"

    AddToBufferJob.perform_later(1)
    @claim = SolidQueue::ReadyExecution.claim("background", 1, 42).sole
  end

  test "a closed connection reconnects on BEGIN and finishes the job" do
    pid = SolidQueue::Record.connection.select_value("SELECT pg_backend_pid()")
    Thread.new do
      SolidQueue::Record.with_connection do |connection|
        assert connection.select_value("SELECT pg_terminate_backend(#{pid})")
        wait_for { !connection.select_value("SELECT 1 FROM pg_stat_activity WHERE pid = #{pid}") }
      end
    end.value

    assert_transactional_finish
  end

  test "a client that cannot cancel a running query finishes in a transaction" do
    PG.stubs(:library_version).returns(18_00_00)
    stub_const(PG, :VERSION, "1.5.9") { assert_transactional_finish }
  end

  test "raising in a thread waiting to finish cancels the statement" do
    assert_interrupted_finish { |thread| thread.raise(Interrupted) }
  end

  test "killing a thread waiting to finish cancels the statement" do
    assert_interrupted_finish { |thread| thread.kill }
  end

  private
    def assert_transactional_finish
      statements = []
      capture = ->(*, payload) { statements << payload[:sql] unless payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(capture, "sql.active_record") { @claim.perform }

      assert_equal [ "BEGIN", "WITH", "COMMIT" ], statements.map { |sql| sql[/\A\w+/] }, statements
      assert @claim.job.reload.finished?
      assert_not SolidQueue::ClaimedExecution.exists?(@claim.id)
    end

    def assert_interrupted_finish
      skip "Client cannot cancel running queries" if PG.library_version >= 18_00_00 && Gem::Version.new(PG::VERSION) < Gem::Version.new("1.6.0")

      pid = Queue.new
      finisher = nil
      SolidQueue::Record.transaction do
        SolidQueue::Job.lock.find(@claim.job_id)
        finisher = Thread.new do
          SolidQueue::Record.with_connection do |connection|
            pid << connection.select_value("SELECT pg_backend_pid()")
            @claim.perform
          rescue Interrupted
            assert_equal 1, connection.select_value("SELECT 1")
          end
        end

        worker_pid = pid.pop
        wait_for(timeout: 5.seconds) do
          SolidQueue::Record.connection.select_value("SELECT pg_backend_pid() = ANY(pg_blocking_pids(#{worker_pid}))")
        end
        yield finisher
        assert finisher.join(5), "finish is still waiting for the lock"
      end

      # The statement deleted the claim before it waited on the job. Lock the
      # claim so this assertion waits for the server to commit or roll back.
      assert SolidQueue::ClaimedExecution.lock.find_by(id: @claim.id)
      assert_not @claim.job.reload.finished?
    ensure
      finisher&.join
    end
end
