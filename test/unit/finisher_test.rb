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
      def finish_group(executions)
        groups << executions
        sleep
      end
  end

  setup do
    @process = SolidQueue::Process.register(kind: "Worker", pid: 42, name: "worker-123")
  end

  teardown do
    @finisher&.stop(1.second)
    SolidQueue.preserve_finished_jobs = true
    SolidQueue::Batch.destroy_all
  end

  test "finishes the executions handed over from many threads, each once" do
    40.times { |i| AddToBufferJob.perform_later(i) }
    claimed = claim_all
    @finisher = SolidQueue::Finisher.new(5).tap(&:start)

    claimed.each_slice(10).map do |executions|
      Thread.new { executions.each { |execution| @finisher.finish(execution) } }
    end.each(&:join)
    @finisher.stop(5.seconds)

    assert_equal 40, SolidQueue::Job.finished.count
    assert_no_claimed_jobs
  end

  test "finishes a group in one transaction" do
    3.times { |i| AddToBufferJob.perform_later(i) }
    claimed = claim_all

    assert_equal 1, commits_during { finish_group(claimed) }
    assert_equal 3, SolidQueue::Job.finished.count
    assert_no_claimed_jobs
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
    assert_no_claimed_jobs
  end

  test "executions handed over after stopping are finished right away" do
    AddToBufferJob.perform_later("late")
    execution = claim_all.sole
    @finisher = SolidQueue::Finisher.new(5).tap(&:start)
    @finisher.stop(5.seconds)

    @finisher.finish(execution)

    assert execution.job.reload.finished?
  end

  test "executions finalized elsewhere are skipped" do
    3.times { |i| AddToBufferJob.perform_later(i) }
    claimed = claim_all
    claimed.first.failed_with(RuntimeError.new)

    finish_group(claimed)

    assert claimed.first.job.reload.failed?
    assert_not claimed.first.job.finished?
    assert_equal claimed.drop(1).map(&:job_id).sort, SolidQueue::Job.finished.pluck(:id).sort
    assert_no_claimed_jobs
  end

  test "a failed group is finished one by one, and one that can't be finished stops the worker" do
    3.times { |i| AddToBufferJob.perform_later(i) }
    claimed = claim_all
    failing = claimed.second
    failing.job.stubs(:finished!).raises(ActiveRecord::Deadlocked)
    unrecoverable = 0
    finisher = SolidQueue::Finisher.new(5, on_unrecoverable_error: -> { unrecoverable += 1 })

    silence_on_thread_error_for(SolidQueue::ClaimedExecution::FinalizationError) do
      finisher.send(:finish_group, claimed)
    end

    assert_equal 1, unrecoverable
    assert_equal (claimed - [ failing ]).map(&:job_id).sort, SolidQueue::Job.finished.pluck(:id).sort
    assert_claimed_jobs 1
  end

  test "deletes the jobs of a group when not keeping finished jobs" do
    SolidQueue.preserve_finished_jobs = false
    3.times { |i| AddToBufferJob.perform_later(i) }

    finish_group(claim_all)

    assert_equal 0, SolidQueue::Job.count
    assert_no_claimed_jobs
  end

  test "a batch whose jobs finish in one group finishes once" do
    batch = SolidQueue::Batch.enqueue(on_finish: BatchCompletionJob) { 3.times { |i| AddToBufferJob.perform_later(i) } }

    finish_group(claim_all)

    assert batch.reload.finished?
    assert_equal 0, SolidQueue::BatchExecution.count
    assert_equal 1, SolidQueue::Job.where(class_name: BatchCompletionJob.name).count
  end

  test "concurrency-limited jobs aren't handed over, so their slots go to the next jobs at once" do
    result = JobResult.create!(queue_name: "default", status: "")
    2.times { |i| NonOverlappingUpdateResultJob.perform_later(result, name: i) }
    execution = claim_all.sole
    execution.finisher = SolidQueue::Finisher.new(5) # Not started: anything handed over would wait

    execution.perform

    assert execution.job.reload.finished?
    assert_equal 0, SolidQueue::BlockedExecution.count
    assert_equal 1, SolidQueue::ReadyExecution.count
  end

  test "a job whose process dies before its group is finished stays claimed until the process is pruned" do
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

    def finish_group(executions)
      SolidQueue::Finisher.new(5).send(:finish_group, executions)
    end

    def commits_during
      commits = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        commits += 1 if payload[:sql].match?(/\Acommit/i)
      end
      yield
      commits
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
end
