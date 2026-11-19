# frozen_string_literal: true

require "test_helper"

# Claims and enqueues on separate connections, for the locks a claim takes, and claims that lose
# a deadlock. Outside of transactional tests, as a deadlock rolls back the whole transaction.
class SolidQueue::ReadyExecutionLockingTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "claiming all of a short queue doesn't wait on a job being enqueued" do
    skip "Row-level locking not supported on SQLite" if SolidQueue::Record.connection.adapter_name.downcase.include?("sqlite")

    # MySQL plans a DELETE of 10 or more ids that are most of the table as a scan of the table
    12.times { |i| AddToBufferJob.perform_later(i) }
    # So that MySQL's statistics know the queue is that short, as they do in a busy queue that's kept short
    SolidQueue::Record.connection.execute("ANALYZE TABLE solid_queue_ready_executions") if mysql?

    enqueued, commit = Concurrent::Event.new, Concurrent::Event.new
    enqueuer = Thread.new do
      SolidQueue::Record.connection_pool.with_connection do
        SolidQueue::Record.transaction do
          SolidQueue::Job.enqueue(AddToBufferJob.new(12))
          enqueued.set
          commit.wait(5)
        end
      end
    end
    assert enqueued.wait(5)

    started = monotonic_now
    claimed = SolidQueue::ReadyExecution.claim("*", 20, 42)
    elapsed = monotonic_now - started

    commit.set
    enqueuer.join

    assert_equal 12, claimed.size
    assert_operator elapsed, :<, 1, "the claim waited #{elapsed.round(2)}s for the enqueue to commit"
    assert_equal 1, SolidQueue::ReadyExecution.count
  ensure
    commit&.set
    enqueuer&.join
  end

  test "make a claim again when it loses a deadlock" do
    3.times { |i| AddToBufferJob.perform_later(i) }
    candidates = SolidQueue::ReadyExecution.order(:id).select(:id, :job_id).to_a

    SolidQueue::ReadyExecution.expects(:select_candidates).times(3)
      .raises(ActiveRecord::Deadlocked).then.raises(ActiveRecord::Deadlocked).then.returns(candidates)

    assert_equal 3, SolidQueue::ReadyExecution.claim("*", 5, 42).size
    assert_equal 3, SolidQueue::ClaimedExecution.count
    assert SolidQueue::ReadyExecution.none?
  end

  test "give up on a claim that keeps losing deadlocks" do
    3.times { |i| AddToBufferJob.perform_later(i) }

    SolidQueue::ReadyExecution.expects(:select_candidates).times(4).raises(ActiveRecord::Deadlocked)

    assert_raises(ActiveRecord::Deadlocked) { SolidQueue::ReadyExecution.claim("*", 5, 42) }
    assert_equal 3, SolidQueue::ReadyExecution.count
  end

  test "don't make a claim again within a transaction that lost a deadlock" do
    3.times { |i| AddToBufferJob.perform_later(i) }

    SolidQueue::ReadyExecution.expects(:select_candidates).once.raises(ActiveRecord::Deadlocked)

    assert_raises(ActiveRecord::Deadlocked) do
      SolidQueue::Record.transaction { SolidQueue::ReadyExecution.claim("*", 5, 42) }
    end
  end

  private
    def mysql?
      SolidQueue::Record.connection.adapter_name.downcase.match?(/mysql|trilogy/)
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
end
