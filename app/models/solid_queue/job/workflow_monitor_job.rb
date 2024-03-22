# frozen_string_literal: true

module SolidQueue
  class Job
    class WorkflowMonitorJob < ActiveJob::Base
      retry_on StandardError, wait: 5.seconds, attempts: 5

      class GoodJobJob < ApplicationJob
        self.queue_adapter = :good_job

        def perform(arg)
          # puts "Hi #{arg}!"
          # raise "doh" if arg == "6"
        end
      end

      # def perform(batch, workflow)
      def perform(workflow)
        # check for finish levels and jobs
        #
        puts "YOYOYOYOYOYOYO"

        # SolidQueue::Workflow.enqueue do |w|
        #   w.run(GoodJobJob.new("1").set(wait_until: 1.second.from_now)) do
        #     w.run(GoodJobJob.new("2")) do
        #       w.run(GoodJobJob.new("3").set(wait_until: 2.seconds.from_now))
        #       w.run(GoodJobJob.new("4"))
        #     end
        #     w.run(GoodJobJob.new("5")) do
        #       w.run(GoodJobJob.new("6")) do
        #         w.run(GoodJobJob.new("7"))
        #         w.run(GoodJobJob.new("7.5"))
        #         w.run(GoodJobJob.new("7.75"))
        #       end
        #       w.run(GoodJobJob.new("6.5"))
        #     end
        #     w.run(GoodJobJob.new("8"), GoodJobJob.new("9"), GoodJobJob.new("10")) do
        #       w.run(GoodJobJob.new("11"), GoodJobJob.new("12"), GoodJobJob.new("13"), GoodJobJob.new("14")) do
        #         w.run(GoodJobJob.new("15"))
        #         w.run(GoodJobJob.new("16"))
        #         w.run(GoodJobJob.new("17"))
        #         w.run(GoodJobJob.new("18")) do
        #           w.run(GoodJobJob.new("19").set(wait_until: 3.seconds.from_now)) do
        #             w.run(GoodJobJob.new("20"))
        #           end
        #           w.run(GoodJobJob.new("21"))
        #           w.run(GoodJobJob.new("22"))
        #           w.run(GoodJobJob.new("23"))
        #         end
        #       end
        #     end
        #   end
        # end
      end
    end
  end
end

# or enqueue a batch job at start of workflow
#   every child workflow batch job is part of it
#   every child workflow batch job enqueues the next level of jobs so it never finishes until they're all done
