require "test_helper"

class SolidQueue::DatabaseAdaptersTest < ActiveSupport::TestCase
  # Runs Base and records each operation it's asked for
  class RecordingAdapter < SolidQueue::DatabaseAdapters::Base
    attr_reader :calls

    def initialize
      @calls = []
    end

    %i[ insert_job enqueue_all release unblock_next claim finish make_ready schedule dispatch_scheduled ].each do |operation|
      define_method(operation) do |*args, &block|
        @calls << [ operation, *args ]
        super(*args, &block)
      end
    end

    def called(operation)
      calls.select { |name, *| name == operation }.map { |_, *args| args }
    end
  end

  class LimitedJob < ApplicationJob
    limits_concurrency key: ->(key) { key }

    def perform(key)
    end
  end

  teardown do
    SolidQueue.database_adapter = nil
  end

  test "PostgreSQL on Active Record 8 or later gets its own adapter, other databases the base one" do
    expected = if SolidQueue::Record.connection.adapter_name == "PostgreSQL" && ActiveRecord.version >= Gem::Version.new("8.0")
      SolidQueue::DatabaseAdapters::Postgresql
    else
      SolidQueue::DatabaseAdapters::Base
    end

    assert_instance_of expected, SolidQueue::Record.database_adapter
    assert_same SolidQueue::Record.database_adapter, SolidQueue::ReadyExecution.database_adapter
  end

  test "an adapter set as SolidQueue.database_adapter is used on every database" do
    SolidQueue.database_adapter = adapter = RecordingAdapter.new

    assert_same adapter, SolidQueue::Record.database_adapter
    assert_same adapter, SolidQueue::Job.database_adapter
  end

  test "enqueuing makes a job ready, or schedules it, through the adapter" do
    SolidQueue.database_adapter = adapter = RecordingAdapter.new

    AddToBufferJob.perform_later(1)
    ready = SolidQueue::Job.last
    AddToBufferJob.set(wait: 1.minute).perform_later(2)
    scheduled = SolidQueue::Job.last

    assert_equal [ [ [ ready ] ] ], adapter.called(:make_ready)
    assert_equal [ [ [ scheduled ] ] ], adapter.called(:schedule)
    assert ready.ready?
    assert scheduled.scheduled?
  end

  test "perform_all_later makes its jobs ready, and schedules them, through the adapter" do
    SolidQueue.database_adapter = adapter = RecordingAdapter.new

    ActiveJob.perform_all_later([ AddToBufferJob.new(1), AddToBufferJob.new(2), AddToBufferJob.new(3).set(wait: 1.minute) ])
    due, not_yet_due = SolidQueue::Job.order(:id).partition(&:due?)

    assert_equal [ due.map(&:id) ], adapter.called(:make_ready).map { |(jobs)| jobs.map(&:id) }
    assert_equal [ not_yet_due.map(&:id) ], adapter.called(:schedule).map { |(jobs)| jobs.map(&:id) }
    assert due.all?(&:ready?)
    assert not_yet_due.all?(&:scheduled?)
  end

  test "dispatching scheduled jobs goes through the adapter" do
    AddToBufferJob.set(wait: 1.minute).perform_later(1)
    job = SolidQueue::Job.last
    SolidQueue.database_adapter = adapter = RecordingAdapter.new

    travel_to 2.minutes.from_now do
      assert_equal 1, SolidQueue::ScheduledExecution.dispatch_next_batch(10)
    end

    assert_equal [ [ 10 ] ], adapter.called(:dispatch_scheduled)
    assert_equal [ [ job.id ] ], adapter.called(:make_ready).map { |(jobs)| jobs.map(&:id) }
    assert job.reload.ready?
  end

  test "a blocked job is made ready through the adapter when it's released" do
    LimitedJob.perform_later("key")
    LimitedJob.perform_later("key")
    blocked = SolidQueue::BlockedExecution.sole
    SolidQueue::Semaphore.delete_all
    SolidQueue.database_adapter = adapter = RecordingAdapter.new

    blocked.release

    assert_equal [ [ blocked.job_id ] ], adapter.called(:make_ready).map { |(jobs)| jobs.map(&:id) }
    assert SolidQueue::Job.find(blocked.job_id).ready?
  end

  test "claiming passes the adapter the whole queue list" do
    AddToBufferJob.set(queue: "backend").perform_later(1)
    AddToBufferJob.set(queue: "background").perform_later(2)
    SolidQueue.database_adapter = adapter = RecordingAdapter.new

    claimed = SolidQueue::ReadyExecution.claim(%w[ backend background ], 5, 42)

    assert_equal [ [ %w[ backend background ], 42, 5 ] ], adapter.called(:claim)
    assert_equal 2, claimed.size
  end
end
