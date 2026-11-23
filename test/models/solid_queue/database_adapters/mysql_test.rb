require "test_helper"

# The adapter only calls code in the models that runs on every database, so
# it's tested on all of them.
class SolidQueue::DatabaseAdapters::MysqlTest < ActiveSupport::TestCase
  setup do
    @adapter = SolidQueue::DatabaseAdapters::Mysql.new
    @process = SolidQueue::Process.register(kind: "Worker", pid: 42, name: "worker-123", metadata: { queue: "background" })
  end

  test "claim loads the claims with their jobs in one query" do
    jobs = 3.times.map { |i| AddToBufferJob.perform_later(i) }

    claimed = nil
    queries = queries_during { claimed = @adapter.claim(SolidQueue::ReadyExecution.queued_as("background"), @process.id, 2) }

    assert_equal jobs.first(2).map(&:provider_job_id), claimed.map(&:job_id).sort
    assert_equal [ @process.id ], claimed.map(&:process_id).uniq
    assert_equal 1, SolidQueue::ReadyExecution.count
    assert_equal 4, queries.size, queries.join("\n")

    assert_empty queries_during { claimed.each { |claim| assert_equal claim.job_id, claim.job.id } }
    assert_equal "AddToBufferJob", claimed.first.job.class_name
  end

  test "claim returns nothing when nothing is ready" do
    assert_empty @adapter.claim(SolidQueue::ReadyExecution.queued_as("background"), @process.id, 2)
  end

  test "finish deletes the claim and finishes the job without reading the claim" do
    claimed_execution = claim_job AddToBufferJob.perform_later(42)

    finished = nil
    queries = queries_during { finished = @adapter.finish(claimed_execution) }

    assert finished
    assert_not SolidQueue::ClaimedExecution.exists?(claimed_execution.id)
    assert claimed_execution.job.reload.finished?
    assert_equal 2, queries.size, queries.join("\n")
    assert_match(/\ADELETE/, queries.first)
  end

  test "finish leaves the job alone when the claim is gone" do
    claimed_execution = claim_job AddToBufferJob.perform_later(42)
    SolidQueue::ClaimedExecution.where(id: claimed_execution.id).delete_all

    assert_not @adapter.finish(claimed_execution)
    assert_not claimed_execution.job.reload.finished?
  end

  test "finish keeps the claim when finishing the job fails" do
    claimed_execution = claim_job AddToBufferJob.perform_later(42)
    SolidQueue::Job.any_instance.stubs(:finished!).raises(ActiveRecord::StatementInvalid.new("transient DB glitch"))

    assert_raises(ActiveRecord::StatementInvalid) { @adapter.finish(claimed_execution) }
    assert SolidQueue::ClaimedExecution.exists?(claimed_execution.id)
  end

  test "finish deletes the job when finished jobs aren't preserved" do
    claimed_execution = claim_job AddToBufferJob.perform_later(42)

    previous, SolidQueue.preserve_finished_jobs = SolidQueue.preserve_finished_jobs, false
    assert @adapter.finish(claimed_execution)
    assert_not SolidQueue::Job.exists?(claimed_execution.job_id)
    assert_not SolidQueue::ClaimedExecution.exists?(claimed_execution.id)
  ensure
    SolidQueue.preserve_finished_jobs = previous
  end

  private
    def claim_job(active_job)
      @adapter.claim(SolidQueue::ReadyExecution.where(job_id: active_job.provider_job_id), @process.id, 1).first
    end

    def queries_during
      queries = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        queries << payload[:sql] unless payload[:name].in?(%w[ SCHEMA TRANSACTION ]) || payload[:cached]
      end
      yield
      queries
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
end
