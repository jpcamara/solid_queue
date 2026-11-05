# frozen_string_literal: true

require "test_helper"

class FinisherTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  # Hands each group to the test instead of finishing it, and waits there
  class StuckFinisher < SolidQueue::Finisher
    attr_reader :groups

    def initialize(...)
      super
      @groups = Thread::Queue.new
    end

    private
      def finish_all(executions)
        groups << executions
        sleep
      end
  end

  setup do
    @process = SolidQueue::Process.register(kind: "Worker", pid: 42, name: "worker-123")
  end

  teardown do
    @finisher&.stop(1.second)
  end

  test "finishes executions handed over from many threads, each once" do
    40.times { |i| AddToBufferJob.perform_later(i) }
    claimed = claim_all
    @finisher = SolidQueue::Finisher.new(5).tap(&:start)

    claimed.each_slice(10).map do |executions|
      Thread.new { executions.each { |execution| @finisher.finish(execution) } }
    end.each(&:join)
    @finisher.stop(5.seconds)

    assert_equal 40, SolidQueue::Job.finished.count
    assert_equal 0, SolidQueue::ClaimedExecution.count
  end

  test "performing a claimed execution hands it over to its finisher" do
    AddToBufferJob.perform_later("hey")
    execution = claim_all.sole
    @finisher = SolidQueue::Finisher.new(5).tap(&:start)

    execution.finisher = @finisher
    execution.perform
    @finisher.stop(5.seconds)

    assert_equal [ "hey" ], JobBuffer.values
    assert execution.job.reload.finished?
    assert_equal 0, SolidQueue::ClaimedExecution.count
  end

  test "executions handed over after stopping are finished right away" do
    AddToBufferJob.perform_later("late")
    execution = claim_all.sole
    @finisher = SolidQueue::Finisher.new(5).tap(&:start)
    @finisher.stop(5.seconds)

    @finisher.finish(execution)

    assert execution.job.reload.finished?
  end

  test "a failed group is finished one by one" do
    3.times { |i| AddToBufferJob.perform_later(i) }
    claimed = claim_all
    @finisher = SolidQueue::Finisher.new(5)
    SolidQueue::ClaimedExecution.expects(:finish_all).with(claimed).raises(ActiveRecord::Deadlocked)
    claimed.each { |execution| SolidQueue::ClaimedExecution.expects(:finish_all).with([ execution ]) }
    SolidQueue.on_thread_error.stubs(:call)

    @finisher.send(:finish_group, claimed)
  end

  test "a job whose process dies before its group is finished stays claimed" do
    AddToBufferJob.perform_later("unfinished")
    execution = claim_all.sole
    finisher = StuckFinisher.new(5).tap(&:start)

    finisher.finish(execution)
    assert_equal [ execution ], Timeout.timeout(1.second) { finisher.groups.pop }
    finisher.send(:thread).kill.join # The process dies

    assert_claimed_jobs 1
    assert_not execution.job.reload.finished?

    # Then the dead process is pruned, as when it dies while performing a job
    @process.prune

    assert_no_claimed_jobs
    assert execution.job.reload.failed?
    assert_not execution.job.finished?
  end

  private
    def claim_all
      SolidQueue::ReadyExecution.claim("*", 100, @process.id)
      SolidQueue::ClaimedExecution.includes(:job).order(:id).to_a
    end
end
