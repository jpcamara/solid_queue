# frozen_string_literal: true

module SolidQueue
  class Job
    class WorkflowCallbackJob < ActiveJob::Base
      def perform(batch, workflow, workflow_level_id)
        # puts "checking batch for workflow_level_id #{workflow_level_id}"
        # apply job finished to nodes
        jobs = batch.jobs
        jobs_by_job_id = jobs.index_by(&:active_job_id)

        ActiveRecord::Base.transaction do
          workflow.workflow_nodes.where(active_job_id: jobs.pluck(:active_job_id)).each do |node|
            # job = jobs.find { |j| j.active_job_id == node.active_job_id }
            jobs = Array.wrap(jobs_by_job_id[node.active_job_id])
            if jobs.any?(&:finished?)
              # node.update!(finished_at: job.finished_at)
              node.update!(finished_at: Time.current)
            end
          end
        end

        # finish workflow if all nodes are done
        workflow.with_lock do
          break if workflow.batch_id?
          break if workflow.workflow_nodes.incomplete.any?
          puts "and here we are..."

          active_job = SolidQueue::Job::WorkflowMonitorJob.perform_later(workflow)
          workflow.update!(batch_id: active_job.job_id)
          puts "#{workflow.id}: and here we are... #{workflow.batch_id} #{workflow_level_id} #{workflow.workflow_nodes.incomplete.count}"
        rescue => e
          binding.pry
          raise
        end

        return if workflow.batch_id?

        workflow.workflow_nodes.incomplete.where(parent_workflow_level_id: workflow_level_id).each do |next_node|
          jobs_to_insert = Workflow.prep_level(workflow, next_node.workflow_level_id)
          Workflow.enqueue_solid_queue(workflow, next_node.workflow_level_id, jobs_to_insert)
        end
      rescue => e
        puts "Error: #{e.message}"
        puts e.backtrace
        raise
      end
    end
  end
end
