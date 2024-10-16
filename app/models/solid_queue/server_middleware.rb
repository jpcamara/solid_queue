# frozen_string_literal: true

module SolidQueue
  class ServerMiddleware
    def call(worker, job, _queue)
      # {
      #   "retry"=>true,
      #   "queue"=>"default",
      #   "wrapped"=>"SolidQueue::WorkflowTest::SidekiqJob",
      #   "args"=>
      #     [{"job_class"=>"SolidQueue::WorkflowTest::SidekiqJob",
      #       "job_id"=>"0f408431-04f1-4744-a2d4-575f4a59feb5",
      #       "provider_job_id"=>nil,
      #       "queue_name"=>"default",
      #       "priority"=>nil,
      #       "arguments"=>["world"],
      #       "executions"=>0,
      #       "exception_executions"=>{},
      #       "locale"=>"en",
      #       "timezone"=>"UTC",
      #       "enqueued_at"=>"2024-02-14T16:02:53.234564000Z",
      #       "scheduled_at"=>nil,
      #       "batch_id"=>nil}],
      #   "class"=>"ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper",
      #   "jid"=>"f964458a2f10e4b38edd364f",
      #   "created_at"=>1707926573.235855,
      #   "enqueued_at"=>1707926643.688022
      # }
      if job["workflow_id"].present?
        active_job_id = job["args"].first["job_id"]
        workflow = SolidQueue::Workflow.find(job["workflow_id"])
        begin
          yield
        ensure
          workflow.workflow_nodes.find_by(active_job_id: active_job_id)&.update!(finished_at: Time.current)
        end
      else
        begin
          yield
        ensure
          puts "the job finished in the middleware #{$!}"
        end
      end
    end
  end
end
