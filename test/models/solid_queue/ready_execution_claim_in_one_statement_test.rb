require "test_helper"

class SolidQueue::ReadyExecutionClaimInOneStatementTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    skip "Needs Active Record 8 or later" if ActiveRecord.version < Gem::Version.new("8.0")

    4.times { |i| AddToBufferJob.set(queue: "backend", priority: 4 - i).perform_later(i) }
    @jobs = SolidQueue::Job.where(queue_name: "backend").order(:priority, :id).to_a
  end

  test "the next ready jobs are claimed, with their jobs loaded, in one statement" do
    claimed = nil
    statements = capturing_statements { claimed = SolidQueue::ReadyExecution.claim("backend", 3, 42) }

    assert_equal @jobs.first(3).map(&:id).sort, claimed.map(&:job_id).sort
    assert_equal SolidQueue::ClaimedExecution.where(job_id: @jobs.first(3)).sort_by(&:id), claimed.sort_by(&:id)
    assert claimed.all? { |claim| claim.process_id == 42 && claim.created_at.present? && !claim.changed? }
    assert_equal [ @jobs.last.id ], SolidQueue::ReadyExecution.pluck(:job_id)

    if postgresql?
      assert_equal [ "WITH" ], verbs(statements.grep_v(/solid_queue_pauses/)), statements
      assert_equal @jobs.first(3).map(&:id), claimed.map(&:job_id), "in the order they were selected"

      jobs = nil
      assert_empty capturing_statements { jobs = claimed.map(&:job) }
      assert_equal @jobs.first(3).map(&:reload).map(&:attributes), jobs.map(&:attributes)
      assert_equal [ [ 3 ], [ 2 ], [ 1 ] ], jobs.map { |job| job.arguments["arguments"] }
      assert jobs.none?(&:changed?)
    end
  end

  test "a claimed job runs without being loaded again" do
    claimed = SolidQueue::ReadyExecution.claim("backend", 1, 42).first

    statements = capturing_statements { claimed.perform }

    assert claimed.job.reload.finished?
    assert statements.none? { |sql| sql.start_with?("SELECT") && sql.include?("solid_queue_jobs") }, statements if postgresql?
  end

  test "the limit carries across the queues in a list, in order" do
    2.times { |i| AddToBufferJob.set(queue: "frontend").perform_later(i) }
    frontend = SolidQueue::Job.where(queue_name: "frontend").order(:id).pluck(:id)

    claimed = SolidQueue::ReadyExecution.claim(%w[ frontend backend ], 3, 42)

    assert_equal frontend.sort, claimed.first(2).map(&:job_id).sort
    assert_equal @jobs.first.id, claimed.last.job_id
    assert_equal 0, SolidQueue::ReadyExecution.claim("backend", 0, 42).size
  end

  test "the limit is kept when claiming from all queues" do
    claimed = SolidQueue::ReadyExecution.claim("*", 2, 42)

    assert_equal @jobs.first(2).map(&:id).sort, claimed.map(&:job_id).sort
    assert_equal [ 42, 42 ], SolidQueue::ClaimedExecution.pluck(:process_id)
  end

  test "a queue name is matched exactly" do
    AddToBufferJob.set(queue: "mail  urgent").perform_later(1)
    AddToBufferJob.set(queue: "mail urgent").perform_later(2)

    claimed = SolidQueue::ReadyExecution.claim("mail  urgent", 2, 42)

    assert_equal [ "mail  urgent" ], claimed.map { |claim| claim.job.queue_name }
  end

  test "claims are timestamped by the database, as before" do
    skip "Needs the transaction's timestamp" unless postgresql?

    SolidQueue::Record.transaction do
      claimed = SolidQueue::ReadyExecution.claim("backend", 1, 42)

      assert SolidQueue::ClaimedExecution.where(id: claimed.first.id).where("created_at = CAST(CURRENT_TIMESTAMP AS timestamp)").exists?
    end
  end

  test "ready executions locked elsewhere are skipped" do
    skip "Needs row locks" if SolidQueue::Record.connection.adapter_name == "SQLite"

    locked, released = Queue.new, Queue.new
    locker = Thread.new do
      SolidQueue::Record.connection_pool.with_connection do
        SolidQueue::Record.transaction do
          SolidQueue::ReadyExecution.where(job_id: @jobs.first.id).lock.load
          locked << true
          released.pop
        end
      end
    end
    locked.pop

    claimer = Thread.new { SolidQueue::ReadyExecution.claim("backend", 2, 42) }

    assert claimer.join(5), "the claim waited on the lock"
    assert_equal @jobs[1, 2].map(&:id).sort, claimer.value.map(&:job_id).sort
  ensure
    released&.push(true)
    locker&.join
    claimer&.join
  end

  test "a job claimed already fails the claim, which leaves the ready executions, as before" do
    SolidQueue::ClaimedExecution.insert_all!([ { job_id: @jobs.second.id, process_id: 7 } ])

    assert_raises(ActiveRecord::RecordNotUnique) { SolidQueue::ReadyExecution.claim("backend", 2, 42) }

    assert_equal 4, SolidQueue::ReadyExecution.count
    assert_equal [ 7 ], SolidQueue::ClaimedExecution.pluck(:process_id)
  end

  test "the claim is instrumented as before" do
    events = []
    callback = ->(event) { events << event.payload }

    ActiveSupport::Notifications.subscribed(callback, "claim.solid_queue") { SolidQueue::ReadyExecution.claim("backend", 2, 42) }

    ids = @jobs.first(2).map(&:id).sort
    assert_equal [ { process_id: 42, job_ids: ids, size: 2, claimed_job_ids: ids } ],
      events.map { |payload| payload.merge(job_ids: payload[:job_ids].sort, claimed_job_ids: payload[:claimed_job_ids].sort) }

    events.clear
    ActiveSupport::Notifications.subscribed(callback, "claim.solid_queue") { SolidQueue::ReadyExecution.claim(%w[ nothing other ], 2, 42) }
    assert_empty events, "nothing claimed, nothing instrumented"
  end

  test "while writes are prevented, jobs are claimed as before, and fail to be" do
    statements = capturing_statements do
      assert_raises(ActiveRecord::ReadOnlyError) do
        SolidQueue::Record.while_preventing_writes { SolidQueue::ReadyExecution.claim("backend", 2, 42) }
      end
    end

    assert statements.none? { |sql| sql.start_with?("WITH") }, statements
    assert_equal 4, SolidQueue::ReadyExecution.count
  end

  test "a query cached before the claim isn't served after it" do
    SolidQueue::Record.cache do
      assert_equal 4, SolidQueue::ReadyExecution.count
      SolidQueue::ReadyExecution.claim("backend", 2, 42)

      assert_equal 2, SolidQueue::ReadyExecution.count
    end
  end

  private
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
