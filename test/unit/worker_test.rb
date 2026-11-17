require "test_helper"
require "active_support/testing/method_call_assertions"

class WorkerTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::MethodCallAssertions
  self.use_transactional_tests = false

  EXECUTION_MODES = [
    {
      name: "thread",
      options: { threads: 3 }
    },
    {
      name: "fiber",
      options: { fibers: 3 }
    }
  ].freeze

  setup do
    @worker = SolidQueue::Worker.new(queues: "background", threads: 3, polling_interval: 0.2)
  end

  teardown do
    @worker.stop
    JobBuffer.clear
  end

  EXECUTION_MODES.each do |mode|
    test "worker is registered as process in #{mode[:name]} mode" do
      with_worker_execution_support(mode[:options]) do
        worker = SolidQueue::Worker.new(queues: "background", polling_interval: 0.2, **mode[:options])

        worker.start
        wait_for_registered_processes(1, timeout: 1.second)

        process = SolidQueue::Process.first
        assert_equal "Worker", process.kind
        assert_metadata process, queues: "background", polling_interval: 0.2, pool_type: mode[:name], pool_size: 3
      ensure
        worker&.stop
        wait_for_registered_processes(0, timeout: 1.second)
      end
    end

    test "claim and process more enqueued jobs than the pool size allows to process at once in #{mode[:name]} mode" do
      5.times do
        StoreResultJob.perform_later(:paused, pause: 0.1.second)
      end

      3.times do
        StoreResultJob.perform_later(:immediate)
      end

      with_worker_execution_support(mode[:options]) do
        worker = SolidQueue::Worker.new(queues: "background", polling_interval: 0.2, **mode[:options])

        worker.start

        wait_for_jobs_to_finish_for(5.seconds)
        worker.wake_up

        assert_equal 5, JobResult.where(queue_name: :background, status: "completed", value: :paused).count
        assert_equal 3, JobResult.where(queue_name: :background, status: "completed", value: :immediate).count
      ensure
        worker&.stop
        wait_for_registered_processes(0, timeout: 1.second)
      end
    end
    test "run every job exactly once when prefetching in #{mode[:name]} mode" do
      30.times { |i| StoreResultJob.perform_later(i, pause: 0.01.seconds) }

      with_worker_execution_support(mode[:options]) do
        worker = SolidQueue::Worker.new(queues: "background", polling_interval: 0.2, prefetch: 4, **mode[:options])

        worker.start

        wait_for_jobs_to_finish_for(5.seconds)

        assert_equal 30.times.map(&:to_s), JobResult.where(status: "completed").pluck(:value).sort_by(&:to_i)
        assert_equal 30, JobResult.count
        assert_no_claimed_jobs
      ensure
        worker&.stop
        wait_for_registered_processes(0, timeout: 1.second)
      end
    end
  end

  test "defaults thread workers to the configured thread pool size" do
    worker = SolidQueue::Worker.new(queues: "background", polling_interval: 0.2)

    worker.start
    wait_for_registered_processes(1, timeout: 1.second)

    assert_equal 3, worker.pool.size
    assert_metadata SolidQueue::Process.first, pool_type: "thread", pool_size: 3
  ensure
    worker&.stop
    wait_for_registered_processes(0, timeout: 1.second)
  end

  test "errors on polling are passed to on_thread_error and re-raised" do
    errors = Concurrent::Array.new

    original_on_thread_error, SolidQueue.on_thread_error = SolidQueue.on_thread_error, ->(error) { errors << error.message }
    previous_thread_report_on_exception, Thread.report_on_exception = Thread.report_on_exception, false

    SolidQueue::ReadyExecution.expects(:claim).raises(ExpectedTestError.new("everything is broken")).at_least_once

    AddToBufferJob.perform_later "hey!"

    worker = SolidQueue::Worker.new(queues: "background", threads: 3, polling_interval: 0.2).tap(&:start)
    sleep(1)

    # stop calls join internally when not supervised, which re-raises the error
    assert_raises ExpectedTestError do
      worker.stop
    end

    assert_equal [ "everything is broken" ], errors
  ensure
    SolidQueue.on_thread_error = original_on_thread_error
    Thread.report_on_exception = previous_thread_report_on_exception
  end

  test "errors on claimed executions are reported via Rails error subscriber regardless of on_thread_error setting" do
    original_on_thread_error, SolidQueue.on_thread_error = SolidQueue.on_thread_error, nil

    subscriber = ErrorBuffer.new
    Rails.error.subscribe(subscriber)

    SolidQueue::ClaimedExecution.any_instance.stubs(:finished).raises(ActiveRecord::StatementInvalid.new("transient DB glitch"))

    AddToBufferJob.perform_later "hey!"

    @worker.start

    wait_for_jobs_to_finish_for(1.second)
    @worker.wake_up

    finalization_errors = subscriber.errors.map(&:first).grep(SolidQueue::ClaimedExecution::FinalizationError)
    assert_equal 1, finalization_errors.count
    assert_match(/transient DB glitch/, finalization_errors.first.message)
  ensure
    Rails.error.unsubscribe(subscriber) if Rails.error.respond_to?(:unsubscribe)
    SolidQueue.on_thread_error = original_on_thread_error
  end

  test "errors on claimed executions are reported via Rails error subscriber" do
    subscriber = ErrorBuffer.new
    Rails.error.subscribe(subscriber)

    RaisingJob.perform_later(ExpectedTestError, "B")

    @worker.start

    wait_for_jobs_to_finish_for(1.second)
    @worker.wake_up

    assert_equal 1, subscriber.errors.count
    assert_equal "This is a ExpectedTestError exception", subscriber.messages.first
  ensure
    Rails.error.unsubscribe(subscriber) if Rails.error.respond_to?(:unsubscribe)
  end

  test "worker stops and releases the claim when finishing a job fails" do
    previous_on_thread_error, SolidQueue.on_thread_error = SolidQueue.on_thread_error, ->(*) { }

    SolidQueue::ClaimedExecution.any_instance.stubs(:finished).raises(ActiveRecord::StatementInvalid.new("transient DB glitch"))

    AddToBufferJob.perform_later "hey!"

    @worker.start

    wait_while_with_timeout(2.seconds) { !@worker.pool.shutdown? }
    assert @worker.pool.shutdown?

    wait_for_registered_processes(0, timeout: 1.second)
    assert_no_registered_processes

    assert_equal 0, SolidQueue::ClaimedExecution.count
    assert SolidQueue::Job.last.reload.ready?
  ensure
    SolidQueue.on_thread_error = previous_on_thread_error
  end

  test "worker keeps running after a regular job failure" do
    RaisingJob.perform_later(ExpectedTestError, "B")
    AddToBufferJob.perform_later "ok"

    @worker.start

    wait_for_jobs_to_finish_for(2.seconds)
    @worker.wake_up

    assert_not @worker.pool.shutdown?
    assert_includes JobBuffer.values, "ok"
    assert_equal 0, SolidQueue::ClaimedExecution.count
  end

  test "polling queries are logged" do
    log = StringIO.new
    polling_query = /SELECT .* FROM .solid_queue_ready_executions. WHERE .solid_queue_ready_executions...queue_name./

    with_active_record_logger(ActiveSupport::Logger.new(log)) do
      with_polling(silence: false) do
        @worker.start
        wait_while_with_timeout(3.seconds) { !log.string.match?(polling_query) }
      end
    end

    assert_match polling_query, log.string
  end

  test "polling queries can be silenced" do
    log = StringIO.new
    with_active_record_logger(ActiveSupport::Logger.new(log)) do
      with_polling(silence: true) do
        @worker.start
        sleep 0.2
      end
    end

    assert_no_match /SELECT .* FROM .solid_queue_ready_executions. WHERE .solid_queue_ready_executions...queue_name./, log.string
  end

  test "silencing polling queries when there's no Active Record logger" do
    with_active_record_logger(nil) do
      with_polling(silence: true) do
        @worker.start
        sleep 0.2
      end
    end

    @worker.stop
    wait_for_registered_processes(0, timeout: 1.second)
    assert_no_registered_processes
  end

  test "run inline" do
    worker = SolidQueue::Worker.new(queues: "*", threads: 3, polling_interval: 0.2)
    worker.mode = :inline

    5.times { |i| StoreResultJob.perform_later(:immediate) }

    worker.start

    assert_equal 5, JobResult.where(queue_name: :background, status: "completed", value: :immediate).count
  end

  test "terminate on heartbeat when unregistered" do
    old_heartbeat_interval, SolidQueue.process_heartbeat_interval = SolidQueue.process_heartbeat_interval, 1.second

    @worker.start
    wait_for_registered_processes(1, timeout: 1.second)

    assert_not @worker.pool.shutdown?

    process = SolidQueue::Process.first
    assert_equal "Worker", process.kind

    process.deregister

    # And now just wait until the worker tries to heartbeat and realises
    # it needs to stop
    wait_while_with_timeout(2) { !@worker.pool.shutdown? }
    assert @worker.pool.shutdown?
  ensure
    SolidQueue.process_heartbeat_interval = old_heartbeat_interval
  end

  test "terminate when heartbeats have been failing for longer than the alive threshold" do
    old_heartbeat_interval, SolidQueue.process_heartbeat_interval = SolidQueue.process_heartbeat_interval, 0.2.seconds
    old_alive_threshold, SolidQueue.process_alive_threshold = SolidQueue.process_alive_threshold, 0.5.seconds

    SolidQueue::Process.any_instance.stubs(:heartbeat).raises(ActiveRecord::StatementInvalid.new("connection lost"))

    @worker.start
    wait_for_registered_processes(1, timeout: 1.second)

    assert_not @worker.pool.shutdown?

    # Heartbeats keep failing without the registration being confirmed gone, so
    # the worker should give up once the failures outlast the alive threshold
    wait_while_with_timeout(3) { !@worker.pool.shutdown? }
    assert @worker.pool.shutdown?
  ensure
    SolidQueue.process_heartbeat_interval = old_heartbeat_interval
    SolidQueue.process_alive_threshold = old_alive_threshold
  end

  test "sleeps `10.minutes` if at capacity" do
    3.times { |i| StoreResultJob.perform_later(i, pause: 5.seconds) }

    delays = stub_interruptible_sleep(@worker)

    @worker.start

    first_delay = Timeout.timeout(1.second) { delays.pop }

    assert_equal 10.minutes, first_delay
  end

  test "sleeps `polling_interval` if worker not at capacity" do
    2.times { |i| StoreResultJob.perform_later(i, pause: 5.seconds) }

    delays = stub_interruptible_sleep(@worker)

    @worker.start

    first_delay = Timeout.timeout(1.second) { delays.pop }

    assert_equal @worker.polling_interval, first_delay
  end

  test "claim only for free threads without prefetch" do
    6.times { |i| StoreResultJob.perform_later(i, pause: 2.seconds) }

    @worker.start
    wait_while_with_timeout(1.second) { JobResult.count < 3 }
    sleep 0.5

    assert_equal 0, @worker.prefetch
    assert_metadata SolidQueue::Process.first, prefetch: 0
    assert_claimed_jobs 3
    assert_equal 3, SolidQueue::ReadyExecution.count
  end

  test "claim up to prefetch jobs ahead of free threads when the queues are deep" do
    7.times { |i| StoreResultJob.perform_later(i, pause: 2.seconds) }

    worker = SolidQueue::Worker.new(queues: "background", threads: 1, prefetch: 4, polling_interval: 0.2)
    delays = stub_interruptible_sleep(worker)

    worker.start

    # A full claim for the free thread, then a full claim ahead, then enough is prefetched
    assert_equal [ 0, 0, 10.minutes ], Timeout.timeout(1.second) { 3.times.map { delays.pop } }
    assert_claimed_jobs 5
    assert_equal 2, SolidQueue::ReadyExecution.count
    assert_equal 1, JobResult.count
    assert_metadata SolidQueue::Process.first, prefetch: 4
  ensure
    worker&.stop
  end

  test "claim only for free threads when the queues are shallow, even with prefetch" do
    2.times { |i| StoreResultJob.perform_later(i, pause: 2.seconds) }

    worker = SolidQueue::Worker.new(queues: "background", threads: 3, prefetch: 4, polling_interval: 0.2)
    delays = stub_interruptible_sleep(worker)

    worker.start

    assert_equal worker.polling_interval, Timeout.timeout(1.second) { delays.pop }
    assert_claimed_jobs 2

    # A claim for the only free thread comes back full, so the worker tries to claim ahead,
    # but that claim comes back short and it goes back to claiming for free threads only
    3.times { |i| StoreResultJob.perform_later(i, pause: 2.seconds) }
    wait_while_with_timeout(1.second) { SolidQueue::ReadyExecution.any? }
    assert_claimed_jobs 5
  ensure
    worker&.stop
  end

  test "release prefetched jobs that haven't started when stopping" do
    StoreResultJob.perform_later(:in_progress, pause: 0.5.seconds)
    4.times { StoreResultJob.perform_later(:prefetched) }

    worker = SolidQueue::Worker.new(queues: "background", threads: 1, prefetch: 4, polling_interval: 0.2).tap(&:start)
    wait_while_with_timeout(1.second) { SolidQueue::ClaimedExecution.count < 5 }
    assert_claimed_jobs 5

    worker.stop
    wait_for_registered_processes(0, timeout: 1.second)

    assert_no_claimed_jobs
    assert_equal [ "in_progress" ], JobResult.where(status: "completed").pluck(:value)
    assert_equal 4, SolidQueue::ReadyExecution.count
  end

  test "fail prefetched jobs with the ones in progress when the worker is killed" do
    in_progress = StoreResultJob.perform_later(:in_progress, pause: 10.seconds)
    prefetched = 4.times.map { StoreResultJob.perform_later(:prefetched) }

    pid = run_supervisor_as_fork(workers: [ { queues: :background, threads: 1, prefetch: 4 } ])
    wait_while_with_timeout!(5.seconds) { JobResult.none? || SolidQueue::ClaimedExecution.count < 5 }

    worker = find_processes_registered_as("Worker").first
    signal_process(worker.pid, :KILL, wait: 0.5.seconds)

    # The supervisor replaces the killed worker, failing every job it had claimed
    wait_while_with_timeout!(5.seconds) { SolidQueue::FailedExecution.count < 5 }

    skip_active_record_query_cache do
      assert_equal [ in_progress, *prefetched ].map(&:job_id).sort, SolidQueue::FailedExecution.joins(:job).pluck(:active_job_id).sort
      assert_equal [ "SolidQueue::Processes::ProcessExitError" ], SolidQueue::FailedExecution.all.map(&:exception_class).uniq
      assert_equal [ "in_progress" ], JobResult.pluck(:value)
    end
  ensure
    terminate_process(pid) if pid && process_exists?(pid)
  end

  private
    def stub_interruptible_sleep(worker)
      delays = Thread::Queue.new

      worker.stubs(:handle_thread_error)
      worker.define_singleton_method(:interruptible_sleep) do |delay|
        delays << delay
        sleep 0.01
      end

      delays
    end

    def with_worker_execution_support(options, &block)
      if options.key?(:fibers)
        with_execution_isolation(:fiber, &block)
      else
        yield
      end
    end

    def with_polling(silence:)
      old_silence_polling, SolidQueue.silence_polling = SolidQueue.silence_polling, silence
      yield
    ensure
      SolidQueue.silence_polling = old_silence_polling
    end

    def with_active_record_logger(logger)
      old_logger, ActiveRecord::Base.logger = ActiveRecord::Base.logger, logger
      yield
    ensure
      ActiveRecord::Base.logger = old_logger
    end
end
