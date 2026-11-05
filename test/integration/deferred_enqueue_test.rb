# frozen_string_literal: true

require "test_helper"

# With enqueue_after_transaction_commit, the jobs Active Job defers until
# after commit are enqueued together, in one transaction.
class DeferredEnqueueTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class CallbackJob < ApplicationJob
    before_enqueue { JobBuffer.add("before #{arguments.first} #{provider_job_id.inspect}") }
    after_enqueue { JobBuffer.add("after #{arguments.first} #{provider_job_id.present?}") }

    def perform(arg)
      JobBuffer.add("ran #{arg}")
    end
  end

  setup do
    skip unless SolidQueue::DeferredEnqueue.supported?

    @enqueue_after_transaction_commit = ApplicationJob.enqueue_after_transaction_commit
    ApplicationJob.enqueue_after_transaction_commit = true
  end

  teardown do
    ApplicationJob.enqueue_after_transaction_commit = @enqueue_after_transaction_commit unless @enqueue_after_transaction_commit.nil?
    SolidQueue::Batch.destroy_all
  end

  test "jobs deferred in a transaction are enqueued in one" do
    jobs = nil
    commits = queue_commits_during do
      jobs = JobResult.transaction do
        JobResult.create!(queue_name: "default", status: "")
        Array.new(10) { |i| AddToBufferJob.perform_later(i) }
      end
    end

    assert jobs.all?(&:provider_job_id)
    assert jobs.all?(&:successfully_enqueued?)
    assert_equal 10, SolidQueue::Job.where(class_name: "AddToBufferJob").count
    assert_equal 1, commits
  end

  test "deferred jobs are enqueued without savepoints" do
    # Elsewhere, a job enqueued on its own still creates its ready execution in a savepoint
    skip unless SolidQueue::Record.connection.adapter_name == "PostgreSQL"

    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }
    JobResult.transaction do
      JobResult.create!(queue_name: "default", status: "")
      5.times { |i| AddToBufferJob.perform_later(i) }
    end
    ActiveSupport::Notifications.unsubscribe(subscriber)

    assert_empty statements.grep(/SAVEPOINT/i)
    assert_equal 5, SolidQueue::Job.where(class_name: "AddToBufferJob").count
  end

  test "the same job deferred twice is enqueued twice, with the options it had each time" do
    job = AddToBufferJob.new("twice")
    JobResult.transaction do
      JobResult.create!(queue_name: "default", status: "")
      job.enqueue(priority: 1)
      job.enqueue(priority: 2)
    end

    assert_equal [ 1, 2 ], SolidQueue::Job.where(class_name: "AddToBufferJob").order(:id).pluck(:priority)
  end

  test "rolled back savepoints drop their jobs" do
    JobResult.transaction do
      JobResult.create!(queue_name: "default", status: "")
      AddToBufferJob.perform_later("kept")
      JobResult.transaction(requires_new: true) do
        AddToBufferJob.perform_later("dropped")
        raise ActiveRecord::Rollback
      end
      AddToBufferJob.perform_later("also kept")
    end

    assert_equal [ "also kept", "kept" ], enqueued_arguments.sort
  end

  test "rolled back transactions drop their jobs" do
    JobResult.transaction do
      JobResult.create!(queue_name: "default", status: "")
      AddToBufferJob.perform_later("dropped")
      raise ActiveRecord::Rollback
    end

    JobResult.transaction do
      JobResult.create!(queue_name: "default", status: "")
      AddToBufferJob.perform_later("enqueued")
    end

    assert_equal [ "enqueued" ], enqueued_arguments
  end

  test "enqueue callbacks run for each job when it's enqueued" do
    JobResult.transaction do
      JobResult.create!(queue_name: "default", status: "")
      CallbackJob.perform_later("a")
      CallbackJob.perform_later("b")

      assert_empty JobBuffer.values
    end

    assert_equal [ "before a nil", "after a true", "before b nil", "after b true" ], JobBuffer.values
  end

  test "scheduled and immediate jobs are enqueued together" do
    commits = queue_commits_during do
      JobResult.transaction do
        JobResult.create!(queue_name: "default", status: "")
        3.times { |i| AddToBufferJob.perform_later(i) }
        2.times { |i| AddToBufferJob.set(wait: 1.hour).perform_later(i) }
      end
    end

    assert_equal 3, SolidQueue::ReadyExecution.count
    assert_equal 2, SolidQueue::ScheduledExecution.count
    assert_equal 1, commits
  end

  test "jobs in a batch are enqueued together and counted" do
    batch = nil
    JobResult.transaction do
      JobResult.create!(queue_name: "default", status: "")
      batch = SolidQueue::Batch.enqueue { 5.times { |i| AddToBufferJob.perform_later(i) } }
    end

    assert_equal 5, batch.reload.total_jobs
    assert_equal 5, batch.batch_executions.count
    assert_equal [ batch.id ], SolidQueue::Job.where(class_name: "AddToBufferJob").distinct.pluck(:batch_id)
  end

  test "jobs outside a transaction are enqueued right away" do
    job = AddToBufferJob.perform_later("now")

    assert job.provider_job_id
  end

  private
    def enqueued_arguments
      SolidQueue::Job.where(class_name: "AddToBufferJob").map { |job| job.arguments["arguments"].first }
    end

    def queue_commits_during
      commits = 0
      queue_database = SolidQueue::Record.connection_db_config.name
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        if payload[:sql].match?(/\Acommit/i) && payload[:connection]&.pool&.db_config&.name == queue_database
          commits += 1
        end
      end
      yield
      commits
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
end
