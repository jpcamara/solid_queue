require "test_helper"

class SolidQueue::JobReadyOnInsertAllTest < ActiveSupport::TestCase
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

  class LimitedToTwoForLongerJob < ApplicationJob
    limits_concurrency key: ->(value, *) { value }, to: 2, duration: 1.hour, group: "limited"

    def perform(value)
    end
  end

  class LimitedToOneJob < ApplicationJob
    limits_concurrency key: ->(value, *) { value }, to: 1, group: "limited"

    def perform(value)
    end
  end

  class LimitedToZeroJob < ApplicationJob
    limits_concurrency key: ->(value, *) { value }, to: 0, group: "limited"

    def perform(value)
    end
  end

  class DiscardingJob < ApplicationJob
    limits_concurrency key: ->(value) { value }, on_conflict: :discard

    def perform(value)
    end
  end

  setup do
    skip "Needs Active Record 8 or later" if ActiveRecord.version < Gem::Version.new("8.0")
  end

  teardown do
    SolidQueue::Batch.destroy_all
  end

  test "limited jobs take as many slots as there are, in the order given, and the rest are blocked" do
    jobs = 3.times.map { |i| LimitedToTwoJob.new("a", i) } + [ AddToBufferJob.new(1) ] + 2.times.map { |i| LimitedToTwoJob.new("b", i) }
    statements = capturing_statements { ActiveJob.perform_all_later(jobs) }
    assert jobs.all?(&:successfully_enqueued?)

    a1, a2, a3 = find(jobs[0..2])
    b1, b2 = find(jobs[4..5])
    assert [ a1, a2, b1, b2 ].all?(&:ready?)
    assert a3.blocked?
    assert find(jobs[3]).first.ready?
    assert_in_delta LimitedToTwoJob.concurrency_duration.from_now, a3.blocked_execution.expires_at, 5.seconds

    a, b = SolidQueue::Semaphore.order(:key).to_a
    assert_equal [ 0, 0 ], [ a.value, b.value ]
    assert_in_delta LimitedToTwoJob.concurrency_duration.from_now, a.expires_at, 5.seconds
    assert_equal [ [ a.id, 2 ] ] * 2 + [ [ b.id, 2 ] ] * 2, [ a1, a2, b1, b2 ].map { |job| [ job.acquired_semaphore_id, job.acquired_concurrency_limit ] }
    assert_nil a3.acquired_semaphore_id

    if postgresql?
      assert_no_match(/SAVEPOINT|FOR UPDATE/, statements.join("\n"))
      assert_equal 1, statements.count { |sql| sql.include?("solid_queue_semaphores") }, statements
      assert_equal 0, statements.count { |sql| sql.match?(/\AUPDATE "solid_queue_jobs"/) }
    end
  end

  test "slots are taken from semaphores that exist, and none from those without any left" do
    LimitedToTwoJob.perform_later("a")
    2.times { LimitedToTwoJob.perform_later("b") }
    room, full = SolidQueue::Semaphore.find_by!(key: "limited/a"), SolidQueue::Semaphore.find_by!(key: "limited/b")
    room.update_columns(expires_at: 1.hour.ago)

    jobs = 2.times.map { LimitedToTwoJob.new("a") } + [ LimitedToTwoJob.new("b") ]
    statements = capturing_statements { ActiveJob.perform_all_later(jobs) }

    took, waits, blocked = find(jobs)
    assert took.ready?
    assert_equal room.id, took.acquired_semaphore_id
    assert waits.blocked?
    assert blocked.blocked?
    assert_equal 0, room.reload.value
    assert_in_delta LimitedToTwoJob.concurrency_duration.from_now, room.expires_at, 5.seconds
    assert_equal full.attributes, full.reload.attributes
    assert_no_match(/SAVEPOINT/, statements.join("\n")) if postgresql?
  end

  test "the arguments stored are what the job records" do
    jobs = [ LimitedToTwoJob.new("a", { "nested" => [ 1, "two" ] }) ]
    ActiveJob.perform_all_later(jobs)

    job = find(jobs).first
    stored = SolidQueue::Record.connection.select_value("SELECT arguments FROM solid_queue_jobs WHERE id = #{job.id}")
    assert_equal SolidQueue::Job.type_for_attribute(:arguments).serialize(job.arguments), stored
    assert_equal "solid_queue_concurrency_lock", job.arguments.keys.last
    assert_equal [ "a", { "nested" => [ 1, "two" ] } ], ActiveJob::Arguments.deserialize(job.arguments["arguments"])
  end

  test "scheduled limited jobs take no slot until they're due" do
    jobs = [ LimitedToTwoJob.new("a").set(wait: 1.hour), LimitedToTwoJob.new("a") ]
    ActiveJob.perform_all_later(jobs)

    scheduled, due = find(jobs)
    assert scheduled.scheduled?
    assert_nil scheduled.acquired_semaphore_id
    assert due.ready?
    assert_equal 1, SolidQueue::Semaphore.sole.value
  end

  test "a set with a job that discards on conflict, or with different limits or durations on one key, is dispatched one at a time" do
    [ [ DiscardingJob.new("x"), LimitedToTwoJob.new("a") ], [ LimitedToTwoJob.new("b"), LimitedToThreeJob.new("b") ], [ LimitedToTwoJob.new("c"), LimitedToTwoForLongerJob.new("c") ] ].each do |jobs|
      statements = capturing_statements { ActiveJob.perform_all_later(jobs) }

      assert find(jobs).all?(&:ready?)
      assert_no_match(/json_to_recordset/, statements.join("\n"))
      assert_match(/SAVEPOINT/, statements.join("\n")) if postgresql?
    end
  end

  test "limited jobs in a batch are counted and tracked" do
    jobs = 3.times.map { LimitedToTwoJob.new("a") }
    batch = SolidQueue::Batch.enqueue { ActiveJob.perform_all_later(jobs) }

    assert_equal 3, batch.reload.total_jobs
    assert_equal [ batch.id ] * 3, find(jobs).map { |job| job.batch_execution.batch_id }
    assert_equal [ true, true, false ], find(jobs).map(&:ready?)
  end

  test "rolled back, the slots taken are given back" do
    LimitedToTwoJob.perform_later("a")

    statements = capturing_statements do
      SolidQueue::Record.transaction do
        ActiveJob.perform_all_later([ LimitedToTwoJob.new("a"), LimitedToTwoJob.new("b") ])
        raise ActiveRecord::Rollback
      end
    end

    assert_equal [ [ "limited/a", 1 ] ], SolidQueue::Semaphore.pluck(:key, :value)
    assert_match(/json_to_recordset/, statements.join("\n")) if postgresql?
  end

  test "a job that can't be serialized fails the set before any slot is taken" do
    SolidQueue::Record.transaction do
      assert_raises(ActiveJob::SerializationError) { ActiveJob.perform_all_later([ LimitedToTwoJob.new("a", Object.new) ]) }
    end

    assert_empty SolidQueue::Semaphore.all
    assert_empty SolidQueue::Job.all
  end

  test "the same job twice, or a limit below 1, is dispatched one at a time" do
    job = LimitedToOneJob.new("a")
    zero = LimitedToZeroJob.new("z")

    [ [ job, job ], [ zero, LimitedToZeroJob.new("z") ] ].each do |jobs|
      statements = capturing_statements { ActiveJob.perform_all_later(jobs) }

      first, second = SolidQueue::Job.where(concurrency_key: jobs.first.concurrency_key).order(:id).to_a
      assert first.ready?
      assert second.blocked?
      assert_no_match(/json_to_recordset/, statements.join("\n"))
    end
  end

  test "a perform_all_later from a callback during another keeps its slots apart" do
    fired = false
    callback = -> { next if fired; fired = true; ActiveJob.perform_all_later([ AddToBufferJob.new(9) ]) }
    SolidQueue::Job.set_callback(:find, :after, callback)

    jobs = [ LimitedToTwoJob.new("a") ]
    begin
      ActiveJob.perform_all_later(jobs)
    ensure
      SolidQueue::Job.skip_callback(:find, :after, callback)
    end

    assert fired
    assert find(jobs).first.ready?
    assert_equal 1, SolidQueue::Semaphore.sole.value
  end

  test "works when connections can't be checked out permanently" do
    previous, ActiveRecord.permanent_connection_checkout = ActiveRecord.permanent_connection_checkout, :disallowed
    jobs = [ LimitedToTwoJob.new("a") ]
    Thread.new { ActiveJob.perform_all_later(jobs) }.join
  ensure
    ActiveRecord.permanent_connection_checkout = previous
    assert jobs.first.successfully_enqueued?
    assert find(jobs).first.ready?
  end

  test "a set takes its batch's lock before its slots, as a single job does, so the two can't deadlock" do
    skip unless postgresql?

    batch = SolidQueue::Batch.enqueue { AddToBufferJob.perform_later(1) }
    batch_locked, results = Queue.new, Queue.new

    single = Thread.new do
      SolidQueue::Record.connection_pool.with_connection do
        SolidQueue::Record.transaction do
          SolidQueue::Batch.wrap_in_batch_context(batch.id) { AddToBufferJob.perform_later(2) }
          batch_locked << true
          wait_for_a_lock_wait
          SolidQueue::Batch.wrap_in_batch_context(batch.id) { results << LimitedToTwoJob.perform_later("k").successfully_enqueued? }
        end
      end
    rescue => error
      results << error
    end

    set = Thread.new do
      SolidQueue::Record.connection_pool.with_connection do
        batch_locked.pop(timeout: 5)
        jobs = [ LimitedToTwoJob.new("k") ]
        SolidQueue::Batch.wrap_in_batch_context(batch.id) { ActiveJob.perform_all_later(jobs) }
        results << jobs.first.successfully_enqueued?
      end
    rescue => error
      results << error
    end

    [ single, set ].each { |thread| thread.join(10) }
    assert_equal [ true, true ], 2.times.map { results.pop(timeout: 1) }
    assert_equal 4, batch.reload.total_jobs
    assert_equal 2, SolidQueue::Job.where(concurrency_key: "limited/k").count(&:ready?)
  end

  test "sets enqueued at the same time on the same keys hand out exactly the slots there are, without deadlocking" do
    skip unless postgresql?

    keys, threads = %w[ a b c d ], 6
    [ :new, :existing ].each do |semaphores|
      SolidQueue::Job.destroy_all
      SolidQueue::Semaphore.delete_all
      keys.each { |key| SolidQueue::Semaphore.create!(key: "limited/#{key}", value: 2, expires_at: 1.hour.from_now) } if semaphores == :existing

      start = Queue.new
      enqueuers = threads.times.map do |i|
        Thread.new do
          SolidQueue::Record.connection_pool.with_connection do
            jobs = keys.rotate(i).flat_map { |key| 2.times.map { LimitedToTwoJob.new(key) } }
            start.pop
            ActiveJob.perform_all_later(jobs)
            jobs.count(&:successfully_enqueued?)
          end
        end
      end
      wait_for_threads_waiting_on(start, threads)
      threads.times { start << true }
      assert_equal [ keys.size * 2 ] * threads, enqueuers.map(&:value), semaphores

      jobs = SolidQueue::Job.all.to_a
      assert_equal keys.to_h { |key| [ "limited/#{key}", 2 ] }, jobs.select(&:ready?).group_by(&:concurrency_key).transform_values(&:size), semaphores
      assert_equal keys.size * (threads * 2 - 2), jobs.count(&:blocked?), semaphores
      assert_equal [ 0 ] * keys.size, SolidQueue::Semaphore.pluck(:value), semaphores
    end
  end

  private
    def postgresql?
      SolidQueue::Record.connection.adapter_name == "PostgreSQL"
    end

    def wait_for_a_lock_wait
      SolidQueue::Record.connection_pool.with_connection do |connection|
        50.times do
          break if connection.select_value("SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'").to_i > 0
          sleep 0.1
        end
      end
    end

    def wait_for_threads_waiting_on(queue, count)
      50.times { queue.num_waiting >= count ? break : sleep(0.1) }
      assert_equal count, queue.num_waiting
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
