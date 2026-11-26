require "test_helper"

class SolidQueue::IdCursorsTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    skip "Needs PostgreSQL and Active Record 8 or later" unless postgresql? && ActiveRecord.version >= Gem::Version.new("8.0")

    @adapter = SolidQueue::DatabaseAdapters.for(SolidQueue::Record.connection)
    @adapter.reset_dispatch_cursors!
    @full_pass_interval = SolidQueue.dispatch_cursors_full_pass_interval
    SolidQueue.dispatch_cursors_full_pass_interval = 10.minutes
  end

  teardown do
    SolidQueue.dispatch_cursors = false
    SolidQueue.dispatch_cursors_full_pass_interval = @full_pass_interval if @full_pass_interval
    @adapter&.reset_dispatch_cursors!
    SolidQueue::Process.destroy_all
  end

  test "finished jobs are cleared in batches that each start where the last one ended" do
    old = insert_jobs(5, finished_at: 2.days.ago)
    recent = insert_jobs(1, finished_at: 1.hour.ago)
    unfinished = insert_jobs(1, finished_at: nil)

    statements = capturing_statements { assert_nil SolidQueue::Job.clear_finished_in_batches(batch_size: 2) }
    deletes = statements.grep(/\ADELETE/)

    assert_equal (recent + unfinished).sort, SolidQueue::Job.where(id: old + recent + unfinished).pluck(:id).sort
    assert_equal 4, deletes.size, deletes
    assert_no_match(/finished_at" >=/, deletes.first)
    assert deletes.drop(1).all? { |sql| sql.include?(%("solid_queue_jobs"."finished_at" >= )) }, deletes
  end

  test "jobs that finished at the same time as the last one in a batch are cleared by the next" do
    at = 2.days.ago.round(6)
    jobs = insert_jobs(5, finished_at: at)

    SolidQueue::Job.clear_finished_in_batches(batch_size: 2)

    assert_not SolidQueue::Job.where(id: jobs).exists?
  end

  test "only jobs of the class given are cleared, and it sleeps after each batch as before" do
    mine = insert_jobs(3, finished_at: 2.days.ago, class_name: "AddToBufferJob")
    others = insert_jobs(2, finished_at: 2.days.ago, class_name: "OtherJob")
    @adapter.expects(:sleep).with(0.01).times(3)

    SolidQueue::Job.clear_finished_in_batches(batch_size: 2, class_name: "AddToBufferJob", sleep_between_batches: 0.01)

    assert_not SolidQueue::Job.where(id: mine).exists?
    assert_equal others.sort, SolidQueue::Job.where(id: others).pluck(:id).sort
  end

  test "the dispatcher reads from the start first, then seeks past the last job it selected" do
    SolidQueue.dispatch_cursors = true
    now = Time.current
    jobs = schedule(2) + schedule(1, wait: 5.minutes)

    travel_to now + 2.minutes
    first = capturing_statements { assert_equal 2, SolidQueue::ScheduledExecution.dispatch_next_batch(10) }
    travel_to now + 6.minutes
    second = capturing_statements { assert_equal 1, SolidQueue::ScheduledExecution.dispatch_next_batch(10) }

    assert_no_match(/\(scheduled_at, priority, job_id\) >/, selects(first).sole)
    assert_match(/\(scheduled_at, priority, job_id\) >/, selects(second).sole)
    assert jobs.all? { |job| job.reload.ready? }
  end

  test "a seek that finds nothing keeps the position" do
    SolidQueue.dispatch_cursors = true
    schedule(1)

    travel 2.minutes do
      assert_equal 1, SolidQueue::ScheduledExecution.dispatch_next_batch(10)
      position = cursor.position

      assert_equal 0, SolidQueue::ScheduledExecution.dispatch_next_batch(10)
      assert_equal position, cursor.position
    end
  end

  test "a job that comes in behind the position waits for the next pass from the start" do
    SolidQueue.dispatch_cursors = true
    schedule(1, wait: 2.minutes)

    travel 3.minutes do
      assert_equal 1, SolidQueue::ScheduledExecution.dispatch_next_batch(10)

      # Due before the job dispatched, as one committed late or scheduled by a clock behind the dispatcher's
      behind = schedule(1, wait: 1.hour).sole
      SolidQueue::ScheduledExecution.where(job_id: behind.id).update_all(scheduled_at: 2.minutes.ago)
      assert_equal 0, SolidQueue::ScheduledExecution.dispatch_next_batch(10)
      assert behind.reload.scheduled?

      @adapter.expire_dispatch_full_passes!
      assert_equal 1, SolidQueue::ScheduledExecution.dispatch_next_batch(10)
      assert behind.reload.ready?
    end
  end

  test "a pass from the start that fills its batch is followed by another" do
    SolidQueue.dispatch_cursors = true
    schedule(3)

    travel 2.minutes do
      assert_equal 2, SolidQueue::ScheduledExecution.dispatch_next_batch(2)
      assert cursor.full_pass_due?

      assert_equal 1, SolidQueue::ScheduledExecution.dispatch_next_batch(2)
      assert_not cursor.full_pass_due?
    end
  end

  test "without dispatch_cursors, the dispatcher reads from the start every time" do
    schedule(3)

    travel 2.minutes do
      statements = capturing_statements { 2.times { SolidQueue::ScheduledExecution.dispatch_next_batch(2) } }

      assert_equal 2, selects(statements).size
      assert selects(statements).none? { |sql| sql.include?("(scheduled_at, priority, job_id) >") }
      assert_equal 0, SolidQueue::ScheduledExecution.count
    end
  end

  private
    def insert_jobs(count, finished_at:, class_name: "AddToBufferJob")
      rows = count.times.map do
        { queue_name: "default", class_name: class_name, arguments: "{}", priority: 0, active_job_id: SecureRandom.uuid,
          finished_at: finished_at, scheduled_at: Time.current, created_at: Time.current, updated_at: Time.current }
      end
      SolidQueue::Job.insert_all!(rows, returning: :id).rows.flatten
    end

    def schedule(count, wait: 1.minute)
      count.times.map do |i|
        SolidQueue::Job.find_by!(active_job_id: AddToBufferJob.set(wait: wait).perform_later(i).job_id)
      end
    end

    def cursor
      @adapter.send(:dispatch_cursor)
    end

    def selects(statements)
      statements.select { |sql| sql.start_with?("SELECT") && sql.include?(%(FROM "solid_queue_scheduled_executions")) && sql.include?("FOR UPDATE SKIP LOCKED") }
    end

    def capturing_statements(&block)
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        statements << payload[:sql].squish unless payload[:name] == "SCHEMA"
      end
      block.call
      statements
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    def postgresql?
      SolidQueue::Record.connection.adapter_name == "PostgreSQL"
    end
end
