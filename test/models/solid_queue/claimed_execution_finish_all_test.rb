# frozen_string_literal: true

require "test_helper"

class SolidQueue::ClaimedExecutionFinishAllTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @process = SolidQueue::Process.register(kind: "Worker", pid: 42, name: "worker-123")
  end

  teardown do
    SolidQueue.preserve_finished_jobs = true
    SolidQueue::Job.destroy_all
    SolidQueue::Batch.destroy_all
  end

  test "finish many executions in one transaction" do
    10.times { |i| AddToBufferJob.perform_later(i) }
    claimed = claim_all

    assert_difference -> { SolidQueue::ClaimedExecution.count } => -10, -> { SolidQueue::Job.finished.count } => 10 do
      assert_equal 1, commits_during { SolidQueue::ClaimedExecution.finish_all(claimed) }
    end
  end

  test "each execution is finalized once" do
    3.times { |i| AddToBufferJob.perform_later(i) }
    claimed = claim_all

    SolidQueue::ClaimedExecution.finish_all(claimed)
    finished_at = SolidQueue::Job.pluck(:id, :finished_at).to_h

    travel 1.minute do
      SolidQueue::ClaimedExecution.finish_all(claimed)
    end

    assert_equal finished_at, SolidQueue::Job.pluck(:id, :finished_at).to_h
  end

  test "executions finalized elsewhere are skipped" do
    3.times { |i| AddToBufferJob.perform_later(i) }
    claimed = claim_all
    failed = claimed.first
    failed.failed_with(RuntimeError.new)

    SolidQueue::ClaimedExecution.finish_all(claimed)

    assert failed.job.reload.failed?
    assert_not failed.job.finished?
    assert_equal claimed.drop(1).map(&:job_id).sort, SolidQueue::Job.finished.pluck(:id).sort
    assert_equal 0, SolidQueue::ClaimedExecution.count
  end

  test "deletes finished jobs when not preserving them" do
    SolidQueue.preserve_finished_jobs = false
    batch = SolidQueue::Batch.enqueue { 3.times { |i| AddToBufferJob.perform_later(i) } }
    AddToBufferJob.perform_later("unbatched")

    SolidQueue::ClaimedExecution.finish_all(claim_all)

    assert_equal 0, SolidQueue::Job.where.not(class_name: BatchCompletionJob.name).count
    assert_equal 0, SolidQueue::ClaimedExecution.count
    assert_equal 0, SolidQueue::BatchExecution.count
    assert batch.reload.finished?
  end

  test "checks each batch for completion once, not once per job" do
    SolidQueue::Batch.enqueue(on_finish: BatchCompletionJob) { 5.times { |i| AddToBufferJob.perform_later(i) } }
    SolidQueue::Batch.enqueue(on_finish: BatchCompletionJob) { 2.times { |i| AddToBufferJob.perform_later(i) } }
    claimed = claim_all

    SolidQueue::Batch.any_instance.expects(:finish).twice
    SolidQueue::ClaimedExecution.finish_all(claimed)

    assert_equal 0, SolidQueue::BatchExecution.count
  end

  test "a batch finishing together enqueues its callback once" do
    batch = SolidQueue::Batch.enqueue(on_finish: BatchCompletionJob) { 5.times { |i| AddToBufferJob.perform_later(i) } }

    SolidQueue::ClaimedExecution.finish_all(claim_all)

    assert batch.reload.finished?
    assert_equal 1, SolidQueue::Job.where(class_name: BatchCompletionJob.name).count
  end

  test "a batch with jobs still pending isn't finished" do
    batch = SolidQueue::Batch.enqueue(on_finish: BatchCompletionJob) { 3.times { |i| AddToBufferJob.perform_later(i) } }
    claimed = claim_all

    SolidQueue::ClaimedExecution.finish_all(claimed.first(2))

    assert_not batch.reload.finished?
    assert_equal 1, batch.batch_executions.count
  end

  test "unblocks the next job of each concurrency-limited job" do
    result_a = JobResult.create!(queue_name: "default", status: "")
    result_b = JobResult.create!(queue_name: "default", status: "")
    2.times { NonOverlappingUpdateResultJob.perform_later(result_a) }
    2.times { NonOverlappingUpdateResultJob.perform_later(result_b) }
    AddToBufferJob.perform_later("plain")

    assert_equal 2, SolidQueue::BlockedExecution.count
    claimed = claim_all

    SolidQueue::ClaimedExecution.finish_all(claimed)

    assert_equal 0, SolidQueue::BlockedExecution.count
    assert_equal 2, SolidQueue::ReadyExecution.count
  end

  private
    def claim_all
      SolidQueue::ReadyExecution.claim("*", 100, @process.id)
      SolidQueue::ClaimedExecution.includes(:job).order(:id).to_a
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
