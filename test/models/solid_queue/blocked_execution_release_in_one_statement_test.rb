require "test_helper"

class SolidQueue::BlockedExecutionReleaseInOneStatementTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class LimitedToTwoJob < ApplicationJob
    limits_concurrency key: ->(value) { value }, to: 2, duration: 3.minutes

    def perform(value)
    end
  end

  setup do
    skip "Needs Active Record 8 or later" if ActiveRecord.version < Gem::Version.new("8.0")
  end

  test "a blocked job is given a slot, has it recorded, and is made ready in one statement" do
    blocked = blocked_job
    signal(blocked)
    semaphore = SolidQueue::Semaphore.find_by!(key: blocked.concurrency_key)
    semaphore.update_column(:expires_at, 1.minute.from_now)
    arguments = blocked.job.arguments

    statements = capturing_statements { assert SolidQueue::BlockedExecution.release_one(blocked.concurrency_key) }

    job = SolidQueue::Job.find(blocked.job_id)
    assert job.ready?
    assert_not SolidQueue::BlockedExecution.exists?(blocked.id)
    assert_equal [ job.queue_name, job.priority ], job.ready_execution.attributes.values_at("queue_name", "priority")
    assert_equal 0, semaphore.reload.value
    assert_in_delta 3.minutes.from_now, semaphore.expires_at, 5.seconds

    lock = { "semaphore_id" => semaphore.id, "limit" => 2 }
    assert_equal arguments.merge(SolidQueue::Job::ConcurrencyControls::CONCURRENCY_LOCK_KEY => lock), job.arguments
    assert_equal JSON.dump(arguments.merge(SolidQueue::Job::ConcurrencyControls::CONCURRENCY_LOCK_KEY => lock)), job.arguments_before_type_cast

    if postgresql?
      assert_equal [ "BEGIN", "SELECT", "SELECT", "WITH", "COMMIT" ], verbs(statements), statements
    end
  end

  test "the job released has its slot in memory too" do
    blocked = blocked_job
    signal(blocked)

    assert blocked.release

    assert_equal SolidQueue::Semaphore.find_by!(key: blocked.concurrency_key).id, blocked.job.acquired_semaphore_id
    assert_equal 2, blocked.job.acquired_concurrency_limit
    assert_not blocked.job.changed?
  end

  test "the job is made ready on its own queue and priority, as before" do
    blocked = blocked_job
    signal(blocked)
    blocked.update_columns(queue_name: "elsewhere", priority: 7)
    SolidQueue::Job.where(id: blocked.job_id).update_all(queue_name: "background", priority: 3)

    assert blocked.reload.release

    assert_equal [ "background", 3 ], SolidQueue::ReadyExecution.find_by!(job_id: blocked.job_id).attributes.values_at("queue_name", "priority")
  end

  test "the job takes its slot on its own concurrency key, as before" do
    blocked = blocked_job
    signal(blocked)
    blocked.update_column(:concurrency_key, "stale")

    assert blocked.release

    assert_equal 0, SolidQueue::Semaphore.find_by!(key: SolidQueue::Job.find(blocked.job_id).concurrency_key).value
    assert_not SolidQueue::Semaphore.exists?(key: "stale")
  end

  test "without a free slot, the job stays blocked and nothing changes" do
    blocked = blocked_job
    arguments = blocked.job.arguments_before_type_cast

    assert_not blocked.release

    assert SolidQueue::BlockedExecution.exists?(blocked.id)
    assert_not SolidQueue::ReadyExecution.exists?(job_id: blocked.job_id)
    assert_equal arguments, SolidQueue::Job.find(blocked.job_id).arguments_before_type_cast
    assert_equal 0, SolidQueue::Semaphore.find_by!(key: blocked.concurrency_key).value
  end

  test "when its semaphore is gone, the job creates it, with the rest of its limit" do
    blocked = blocked_job
    SolidQueue::Semaphore.where(key: blocked.concurrency_key).delete_all

    assert blocked.release

    semaphore = SolidQueue::Semaphore.find_by!(key: blocked.concurrency_key)
    assert_equal 1, semaphore.value
    assert_equal semaphore.id, SolidQueue::Job.find(blocked.job_id).acquired_semaphore_id
    assert SolidQueue::Job.find(blocked.job_id).ready?
  end

  test "a job whose class doesn't load, with changes to save, or whose arguments can't take the slot, is released as before" do
    blocked = blocked_job("gone")
    signal(blocked)
    SolidQueue::Job.where(id: blocked.job_id).update_all(class_name: "GoneJob")
    assert_no_one_statement_release { blocked.reload.release }
    assert SolidQueue::Job.find(blocked.job_id).failed?

    blocked = blocked_job("changed")
    signal(blocked)
    blocked.job.arguments["arguments"] = [ "edited" ]
    assert_no_one_statement_release { blocked.release }
    assert_equal [ "edited" ], SolidQueue::Job.find(blocked.job_id).arguments["arguments"]
    assert SolidQueue::Job.find(blocked.job_id).ready?

    blocked = blocked_job("recorded")
    signal(blocked)
    blocked.job.arguments[SolidQueue::Job::ConcurrencyControls::CONCURRENCY_LOCK_KEY] = { "semaphore_id" => nil, "limit" => nil }
    blocked.job.update_column(:arguments, blocked.job.arguments)
    assert_no_one_statement_release { blocked.reload.release }
    assert SolidQueue::Job.find(blocked.job_id).ready?

    blocked = blocked_job("newline")
    signal(blocked)
    SolidQueue::Job.where(id: blocked.job_id).update_all([ "arguments = ?", "#{blocked.job.arguments_before_type_cast}\n" ])
    assert_no_one_statement_release { blocked.reload.release }
    assert SolidQueue::Job.find(blocked.job_id).ready?
    assert SolidQueue::Job.find(blocked.job_id).acquired_semaphore_id
  end

  test "a read-only blocked execution isn't released, as before" do
    blocked = blocked_job
    signal(blocked)

    blocked.readonly!
    assert_raises(ActiveRecord::ReadOnlyRecord) { blocked.release }

    assert SolidQueue::BlockedExecution.exists?(blocked.id)
    assert_not SolidQueue::ReadyExecution.exists?(job_id: blocked.job_id)
  end

  test "while writes are prevented, the job is released as before, and fails to be" do
    blocked = blocked_job
    signal(blocked)

    statements = capturing_statements do
      assert_raises(ActiveRecord::ReadOnlyError) do
        SolidQueue::Record.while_preventing_writes { blocked.release }
      end
    end

    assert statements.none? { |sql| sql.start_with?("WITH") }, statements
    assert SolidQueue::BlockedExecution.exists?(blocked.id)
  end

  test "the release is instrumented as before" do
    blocked = blocked_job
    signal(blocked)

    events = []
    callback = ->(event) { events << event.payload }
    ActiveSupport::Notifications.subscribed(callback, "release_blocked.solid_queue") { blocked.release }

    assert_equal [ { job_id: blocked.job_id, concurrency_key: blocked.concurrency_key, released: true } ], events
  end

  test "a query cached before the release isn't served after it" do
    blocked = blocked_job
    signal(blocked)

    SolidQueue::Record.cache do
      assert_equal 0, SolidQueue::ReadyExecution.where(job_id: blocked.job_id).count
      blocked.release

      assert_equal 1, SolidQueue::ReadyExecution.where(job_id: blocked.job_id).count
    end
  end

  test "expired blocked jobs are released by the dispatcher through it" do
    blocked = blocked_job
    signal(blocked)
    blocked.update_column(:expires_at, 1.minute.ago)

    statements = capturing_statements { assert_equal 1, SolidQueue::BlockedExecution.unblock(10) }

    assert SolidQueue::Job.find(blocked.job_id).ready?
    assert statements.any? { |sql| sql.start_with?("WITH semaphore") }, statements if postgresql?
  end

  private
    # Two jobs fill the slots of the key; the third is blocked
    def blocked_job(key = "key")
      3.times.map { LimitedToTwoJob.perform_later(key) }
      SolidQueue::BlockedExecution.find_by!(job_id: SolidQueue::Job.last.id)
    end

    def signal(blocked)
      SolidQueue::Semaphore.where(key: blocked.concurrency_key).update_all("value = value + 1")
    end

    def assert_no_one_statement_release(&block)
      statements = capturing_statements(&block)
      assert statements.none? { |sql| sql.start_with?("WITH") }, statements
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
end
