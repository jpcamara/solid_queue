require "test_helper"

class SolidQueue::WorkflowTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @pid = run_supervisor_as_fork(mode: :all)
    wait_for_registered_processes(3, timeout: 3.second)
  end

  teardown do
    terminate_process(@pid) if process_exists?(@pid)

    SolidQueue::JobBatch.destroy_all
    SolidQueue::WorkflowNode.destroy_all
    SolidQueue::Workflow.destroy_all
    SolidQueue::Process.destroy_all
    SolidQueue::Job.destroy_all
    RedisClient.new.call("flushdb")
  end

  class NiceJob < ApplicationJob
    # retry_on Exception, wait: 1.second

    def perform(arg)
      puts "Hi #{arg}!"
    end
  end

  class Oops < StandardError; end

  class SidekiqJob < ApplicationJob
    retry_on Exception, wait: 1.second, attempts: 3
    discard_on Oops

    sidekiq_options retry: 2

    self.queue_adapter = :sidekiq

    def perform(arg)
      # raise Oops # This triggers and on_success...
      puts "Hi #{arg}, from sidekiq!", "", ""
      raise "eek"
    end
  end

  # class GoodJobJob < ApplicationJob
  #   retry_on Exception, wait: 1.second, attempts: 3
  #   discard_on Oops

  #   sidekiq_options retry: 2

  #   self.queue_adapter = :good_job

  #   def perform(arg)
  #     puts "Hi #{arg}, from good job!", "", ""
  #     # raise Oops
  #     raise "eek"
  #   end
  # end

  class GoodJobJob < ApplicationJob
    self.queue_adapter = :good_job

    def perform(arg)
      puts "Hi #{arg}!"
      # raise "doh" if arg == "6"
    end
  end

  class GoodBatchCallbackJob < ApplicationJob
    self.queue_adapter = :good_job

    def perform(batch, params)
      puts "Here's how many jobs we ran: #{batch.active_jobs.size}"
    end
  end

  class MyCallback
    def on_complete(status, options)
      puts "Uh oh, batch has failures" if status.failures != 0
    end

    def on_success(status, options)
      puts "#{options['uid']}'s batch succeeded.  Kudos!"
    end
  end

  # When these jobs have finished, it will enqueue your `MyBatchCallbackJob.perform_later(batch, options)`
  class MyBatchCallbackJob < ApplicationJob
    self.queue_adapter = :good_job

    # Callback jobs must accept a `batch` and `options` argument
    def perform(batch, params)
      ap params
      ap GoodJob::Job.where(active_job_id: batch.active_jobs.map(&:job_id))
    end
  end

  # test "good job batches" do
  #   Thread.new do
  #     capsule = GoodJob.capsule
  #     capsule.start
  #   end

  #   # loop do
  #   SolidQueue::Workflow.enqueue do |w|
  #     w.run(GoodJobJob.new("1").set(wait_until: 1.second.from_now)) do
  #       w.run(GoodJobJob.new("2")) do
  #         w.run(GoodJobJob.new("3").set(wait_until: 2.seconds.from_now))
  #         w.run(GoodJobJob.new("4"))
  #       end
  #       w.run(GoodJobJob.new("5")) do
  #         w.run(GoodJobJob.new("6")) do
  #           w.run(GoodJobJob.new("7"))
  #           w.run(GoodJobJob.new("7.5"))
  #           w.run(GoodJobJob.new("7.75"))
  #           w.run(GoodJobJob.new("7.9")) do
  #             w.run(GoodJobJob.new("7.95"))
  #             w.run(GoodJobJob.new("7.97"))
  #             w.run(GoodJobJob.new("7.99"))
  #           end
  #         end
  #         w.run(GoodJobJob.new("6.5"))
  #       end
  #       w.run(GoodJobJob.new("8"), GoodJobJob.new("9"), GoodJobJob.new("10")) do
  #         w.run(GoodJobJob.new("11"), GoodJobJob.new("12"), GoodJobJob.new("13"), GoodJobJob.new("14")) do
  #           w.run(GoodJobJob.new("15")) do
  #             w.run(GoodJobJob.new("15.1")) do
  #               w.run(GoodJobJob.new("15.2"))
  #             end
  #           end
  #           w.run(GoodJobJob.new("16"))
  #           w.run(GoodJobJob.new("17"))
  #           w.run(GoodJobJob.new("18")) do
  #             w.run(GoodJobJob.new("19").set(wait_until: 3.seconds.from_now)) do
  #               w.run(GoodJobJob.new("20"))
  #             end
  #             w.run(GoodJobJob.new("21"))
  #             w.run(GoodJobJob.new("22"))
  #             w.run(GoodJobJob.new("23"))
  #           end
  #         end
  #       end
  #     end
  #   end
  #   # sleep 5
  #   # end

  #   sleep 120
  # end

  # test "sidekiq batches" do
  #   $sidekiq_instance = Sidekiq.configure_embed do |config|
  #     config.queues = %w[background default realtime reports]
  #     config.concurrency = 1
  #   end
  #   $sidekiq_instance.run

  #   batch = Sidekiq::Batch.new
  #   %i[success death].each do |event|
  #     batch.on(
  #       event,
  #       SolidQueue::Job::WorkflowSidekiqBatchCallback,
  #       stuff: 123,
  #       and_junk: 234
  #     )
  #   end
  #   batch.jobs do
  #     ActiveJob.perform_all_later([
  #       SidekiqJob.new("1"),
  #       SidekiqJob.new("2"),
  #       SidekiqJob.new("3")
  #     ])
  #   end

  #   sleep 120
  # end

  test "sets the batch_id on jobs created inside of the enqueue block" do
    SolidQueue::Workflow.enqueue do |w|
      w.run(NiceJob.new("1").set(wait_until: 1.second.from_now)) do
        w.run(NiceJob.new("2")) do
          w.run(NiceJob.new("3").set(wait_until: 2.seconds.from_now))
          w.run(NiceJob.new("4"))
        end
        w.run(NiceJob.new("5")) do
          w.run(NiceJob.new("6")) do
            w.run(NiceJob.new("7"))
            w.run(NiceJob.new("7.5"))
            w.run(NiceJob.new("7.75"))
            w.run(NiceJob.new("7.9")) do
              w.run(NiceJob.new("7.95"))
              w.run(NiceJob.new("7.97"))
              w.run(NiceJob.new("7.99"))
            end
          end
          w.run(NiceJob.new("6.5"))
        end
        w.run(NiceJob.new("8"), NiceJob.new("9"), NiceJob.new("10")) do
          w.run(NiceJob.new("11"), NiceJob.new("12"), NiceJob.new("13"), NiceJob.new("14")) do
            w.run(NiceJob.new("15")) do
              w.run(NiceJob.new("15.1")) do
                w.run(NiceJob.new("15.2"))
              end
            end
            w.run(NiceJob.new("16"))
            w.run(NiceJob.new("17"))
            w.run(NiceJob.new("18")) do
              w.run(NiceJob.new("19").set(wait_until: 3.seconds.from_now)) do
                w.run(NiceJob.new("20"))
              end
              w.run(NiceJob.new("21"))
              w.run(NiceJob.new("22"))
              w.run(NiceJob.new("23"))
            end
          end
        end
      end
    end

    # SolidQueue::Workflow.enqueue do |w|
    #   w.run(NiceJob.new("1").set(wait_until: 1.second.from_now)) do
    #     w.run(NiceJob.new("2")) do
    #       w.run(NiceJob.new("3").set(wait_until: 2.seconds.from_now))
    #       w.run(NiceJob.new("4"))
    #     end
    #     w.run(NiceJob.new("5")) do
    #       w.run(NiceJob.new("6")) do
    #         w.run(NiceJob.new("7"))
    #       end
    #     end
    #     w.run(NiceJob.new("8"), NiceJob.new("9"), NiceJob.new("10")) do
    #       w.run(NiceJob.new("11"), NiceJob.new("12"), NiceJob.new("13"), NiceJob.new("14")) do
    #         w.run(NiceJob.new("15"))
    #         w.run(NiceJob.new("16"))
    #         w.run(NiceJob.new("17"))
    #         w.run(NiceJob.new("18")) do
    #           w.run(NiceJob.new("19").set(wait_until: 3.seconds.from_now))
    #           w.run(NiceJob.new("20"))
    #           w.run(NiceJob.new("21"))
    #           w.run(NiceJob.new("22"))
    #         end
    #       end
    #     end
    #   end
    # end
    DiscardJob.perform_later("123")

    sleep 10

    binding.pry
  end

  class DiscardJob < ApplicationJob
    # retry_on Exception, wait: 1.second, attempts: 3
    discard_on Oops

    # has_one :ready_execution
    # has_one :claimed_execution
    # has_one :failed_execution
    def perform(arg)
      puts "Hi #{arg}, time to discard!"
      raise Oops # This triggers and on_success...
    end
  end
end
