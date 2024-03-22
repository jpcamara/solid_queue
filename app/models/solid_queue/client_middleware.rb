# frozen_string_literal: true

module SolidQueue
  class ClientMiddleware
    def call(_worker_class, job, _queue, _redis_pool)
      # {
      #   "retry"=>true,
      #   "queue"=>"default",
      #   "class"=>"ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper",
      #   "wrapped"=>SolidQueue::WorkflowTest::SidekiqJob,
      #   "args"=>
      #     [{"job_class"=>"SolidQueue::WorkflowTest::SidekiqJob",
      #       "job_id"=>"e5db262e-2c49-4556-a2e4-78c009105e5d",
      #       "provider_job_id"=>nil,
      #       "queue_name"=>"default",
      #       "priority"=>nil,
      #       "arguments"=>["world"],
      #       "executions"=>0,
      #       "exception_executions"=>{},
      #       "locale"=>"en",
      #       "timezone"=>"UTC",
      #       "enqueued_at"=>"2024-02-14T16:29:36.752639000Z",
      #       "scheduled_at"=>nil,
      #       "batch_id"=>nil}],
      #   "jid"=>"185f9fb47e6610a31a576f72",
      #   "created_at"=>1707928176.753821
      # }
      # job["args"].first["batch_id"] = JobBatch.current_batch_id
      # process_queue_job = job["args"].first
      # job["process_queue_id"] = process_queue_job.id
      # job["args"] = process_queue_job.args
      # update_jid(process_queue_job)
      if SolidQueue::Workflow.current_workflow.present?
        job["workflow_id"] = SolidQueue::Workflow.current_workflow.id
      end

      yield
    end
  end
end
