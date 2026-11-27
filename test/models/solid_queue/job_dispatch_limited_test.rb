require "test_helper"

class SolidQueue::JobDispatchLimitedTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class LimitedToTwoJob < ApplicationJob
    limits_concurrency key: ->(value, *) { value }, to: 2, group: "limited"

    def perform(value)
    end
  end

  class LimitedToThreeJob < ApplicationJob
    limits_concurrency key: ->(value, *) { value }, to: 3, group: "limited"

    def perform(value)
    end
  end

  class LimitedToZeroJob < ApplicationJob
    limits_concurrency key: ->(value, *) { value }, to: 0, group: "limited"

    def perform(value)
    end
  end

  class CappedJob < ApplicationJob
    limits_concurrency key: ->(value, *) { value }, max_blocked: 1, group: "capped"

    def perform(value)
    end
  end

  class DiscardingJob < ApplicationJob
    limits_concurrency key: ->(value, *) { value }, on_conflict: :discard, group: "discarding"

    def perform(value)
    end
  end

  setup do
    skip "Needs Active Record 8 or later" if ActiveRecord.version < Gem::Version.new("8.0")
  end

  teardown do
    SolidQueue::Batch.destroy_all
  end

  test "scheduled limited jobs coming due take their slots together, by key and then id" do
    jobs = 3.times.map { |i| LimitedToTwoJob.new("a", i) } + [ LimitedToTwoJob.new("b"), AddToBufferJob.new(1) ]
    schedule(jobs)

    statements = capturing_statements { assert_equal 5, SolidQueue::ScheduledExecution.dispatch_next_batch(10) }

    a1, a2, a3, b, unlimited = find(jobs)
    assert [ a1, a2, b, unlimited ].all?(&:ready?)
    assert a3.blocked?
    assert_in_delta LimitedToTwoJob.concurrency_duration.from_now, a3.blocked_execution.expires_at, 5.seconds
    assert_empty SolidQueue::ScheduledExecution.all

    assert_equal [ 0, 1 ], semaphore_values("limited/a", "limited/b")
    assert_not_nil a1.acquired_semaphore_id
    assert_equal a1.acquired_semaphore_id, a2.acquired_semaphore_id
    assert_equal [ 2, 2 ], [ a1.acquired_concurrency_limit, b.acquired_concurrency_limit ]
    assert_nil a3.acquired_semaphore_id
    stored = SolidQueue::Record.connection.select_value("SELECT arguments FROM solid_queue_jobs WHERE id = #{a1.id}")
    assert_equal SolidQueue::Job.type_for_attribute(:arguments).serialize(a1.arguments), stored

    if postgresql?
      assert_no_match(/SAVEPOINT/, statements.join("\n"))
      assert_equal 1, statements.count { |sql| sql.start_with?('UPDATE "solid_queue_jobs"') }, statements
    end
  end

  test "dispatching scheduled limited jobs takes as many statements however many there are" do
    skip unless postgresql?

    counts = [ 3, 8 ].map do |size|
      jobs = size.times.map { |i| LimitedToTwoJob.new("key#{size}", i) } + size.times.map { |i| CappedJob.new("key#{size}", i) }
      schedule(jobs)
      capturing_statements { SolidQueue::ScheduledExecution.dispatch_next_batch(100) }.size
    end

    assert_equal counts.first, counts.last
  end

  test "scheduled jobs over max_blocked, or that discard on conflict, are deleted when they come due" do
    jobs = 4.times.map { CappedJob.new("key") } + 2.times.map { DiscardingJob.new("key") }
    schedule(jobs)

    statements = capturing_statements { assert_equal 3, SolidQueue::ScheduledExecution.dispatch_next_batch(10) }

    ready, blocked, *discarded, discarding_ready, discarding_discarded = find(jobs)
    assert ready.ready?
    assert blocked.blocked?
    assert discarding_ready.ready?
    assert_equal [ nil, nil, nil ], [ *discarded, discarding_discarded ]
    assert_empty SolidQueue::ScheduledExecution.all
    assert_equal 1, statements.count { |sql| sql.start_with?('DELETE FROM "solid_queue_jobs"') }, statements if postgresql?
  end

  test "a scheduled job discarded from its batch is destroyed, so the batch can finish" do
    CappedJob.perform_later("key")
    CappedJob.perform_later("key")

    batch = SolidQueue::Batch.enqueue { CappedJob.set(wait: 1.minute).perform_later("key") }
    make_due
    SolidQueue::ScheduledExecution.dispatch_next_batch(10)

    assert_equal 2, SolidQueue::Job.count
    assert_empty SolidQueue::BatchExecution.where(batch_id: batch.id)
    assert batch.reload.finished?
  end

  test "failed limited jobs retried together take their slots together, replacing those they recorded" do
    jobs = 3.times.map { |i| LimitedToTwoJob.new("a", i) }
    ActiveJob.perform_all_later(jobs)
    find(jobs).each do |job|
      job.blocked_execution&.destroy!
      job.ready_execution&.destroy!
      job.failed_with(RuntimeError.new("boom"))
    end
    expire_semaphores

    statements = capturing_statements { assert_equal 3, SolidQueue::FailedExecution.retry_all(SolidQueue::Job.where(id: find(jobs).map(&:id))) }

    first, second, third = find(jobs)
    assert first.ready?
    assert second.ready?
    assert third.blocked?
    assert_equal first.acquired_semaphore_id, second.acquired_semaphore_id
    assert_nil third.acquired_semaphore_id
    assert_equal 1, first.arguments.keys.count { |key| key == SolidQueue::Job::ConcurrencyControls::CONCURRENCY_LOCK_KEY }
    assert_empty SolidQueue::FailedExecution.all
    assert_no_match(/SAVEPOINT/, statements.join("\n")) if postgresql?
  end

  test "a set with a job whose class doesn't load, a limit below 1, or different limits on one key is dispatched one at a time" do
    missing = SolidQueue::Job.create!(queue_name: "default", class_name: "NoSuchJob", arguments: { "arguments" => [] }, concurrency_key: "missing", active_job_id: SecureRandom.uuid, scheduled_at: 1.minute.from_now)

    [ [ LimitedToTwoJob.new("x") ], [ LimitedToZeroJob.new("z"), LimitedToZeroJob.new("z") ], [ LimitedToTwoJob.new("m"), LimitedToThreeJob.new("m") ] ].each_with_index do |jobs, i|
      schedule(jobs)
      statements = capturing_statements { SolidQueue::ScheduledExecution.dispatch_next_batch(10) }

      first, second = find(jobs)
      assert first.ready?
      assert(i == 1 ? second.blocked? : second.nil? || second.ready?)
      assert missing.reload.ready? if i == 0
      assert_no_match(/json_to_recordset/, statements.join("\n"))
    end
  end

  private
    def schedule(jobs)
      ActiveJob.perform_all_later(jobs.map { |job| job.set(wait: 1.minute) })
      make_due
    end

    def make_due
      SolidQueue::Job.where(id: SolidQueue::ScheduledExecution.select(:job_id)).update_all(scheduled_at: 1.minute.ago)
      SolidQueue::ScheduledExecution.update_all(scheduled_at: 1.minute.ago)
    end

    def semaphore_log?
      SolidQueue::Job.database_adapter.is_a?(SolidQueue::DatabaseAdapters::PostgresqlWithSemaphoreLog)
    end

    def semaphore_values(*keys)
      if semaphore_log?
        keys.map { |key| SolidQueue::Record.connection.select_value("SELECT value FROM solid_queue_semaphore_log WHERE key = #{SolidQueue::Record.connection.quote(key)} ORDER BY id DESC LIMIT 1") }
      else
        keys.map { |key| SolidQueue::Semaphore.find_by!(key: key).value }
      end
    end

    def expire_semaphores
      if semaphore_log?
        SolidQueue::Record.connection.execute("UPDATE solid_queue_semaphore_log SET expires_at = now() - interval '1 minute'")
      else
        SolidQueue::Semaphore.update_all(expires_at: 1.minute.ago)
      end
      SolidQueue::Job.database_adapter.expire_semaphores(10)
    end

    def postgresql?
      SolidQueue::Record.connection.adapter_name == "PostgreSQL"
    end

    def find(active_jobs)
      SolidQueue::Job.where(active_job_id: Array(active_jobs).map(&:job_id)).index_by(&:active_job_id).values_at(*Array(active_jobs).map(&:job_id))
    end

    def capturing_statements(&block)
      statements = []
      callback = ->(*, payload) { statements << payload[:sql] unless payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
      statements
    end
end
