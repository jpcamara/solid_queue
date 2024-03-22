# frozen_string_literal: true

module SolidQueue
  class Job
    class WorkflowGoodJobCallbackJob < ActiveJob::Base
      def perform(batch, params)
        workflow = batch.properties[:workflow]
        workflow_level_id = batch.properties[:workflow_level_id]

        ActiveRecord::Base.transaction do
          # Mark nodes a finished or failed
          any_discarded = mark_node_completion(workflow, batch)

          # If any jobs in the level were discarded, discard the level and all its descendents
          discard_descendents(workflow, workflow_level_id) if any_discarded
        end

        attempt_finish(workflow, workflow_level_id)

        return if workflow.batch_id?

        # enqueue next level of jobs
        enqueue_next_levels(workflow, workflow_level_id)
      rescue StandardError => e
        puts "Error: #{e.message}"
        puts e.backtrace
        raise
      end

      def attempt_finish(workflow, workflow_level_id)
        # Finish workflow if all nodes are done
        workflow.with_lock do
          return if workflow.batch_id?
          return if workflow.workflow_nodes.incomplete.any?

          active_job = SolidQueue::Job::WorkflowMonitorJob.perform_later(workflow)
          workflow.update!(batch_id: active_job.job_id)
          puts "#{workflow.id}: and here we are... #{workflow.batch_id} #{workflow_level_id} #{workflow.workflow_nodes.incomplete.count}"
        rescue StandardError => e
          puts "Error: #{e.message}"
          puts e.backtrace
          raise
        end
      end

      def mark_node_completion(workflow, batch)
        active_jobs = batch.active_jobs
        good_jobs = GoodJob::Job.where(active_job_id: active_jobs.map(&:job_id)) # only get the last run
        jobs_by_job_id = good_jobs.index_by(&:active_job_id)
        any_discarded = false

        workflow.workflow_nodes.where(active_job_id: jobs_by_job_id.keys).each do |node|
          next unless node.incomplete?

          jobs = Array.wrap(jobs_by_job_id[node.active_job_id])
          if jobs.any?(&:discarded?)
            any_discarded = true
            # node.update!(discarded_at: job.discarded_at)
            node.update!(discarded_at: Time.current)
          elsif jobs.any?(&:finished?)
            # node.update!(finished_at: job.finished_at)
            node.update!(finished_at: Time.current)
          end
        end

        any_discarded
      end

      def discard_descendents(workflow, workflow_level_id)
        # get descendents and discard them
        child_nodes = WorkflowNode.descendants(workflow, workflow_level_id)
        SolidQueue::WorkflowNode
          .where(workflow: workflow, workflow_level_id: child_nodes.pluck(:workflow_level_id))
          .update_all(discarded_at: Time.current)
      end

      def enqueue_next_levels(workflow, workflow_level_id)
        # ActiveRecord::Base.transaction - causes a deadlock in #prep_node
        workflow.workflow_nodes.incomplete.where(parent_workflow_level_id: workflow_level_id).each do |next_node|
          jobs_to_insert = Workflow.prep_level(workflow, next_node.workflow_level_id)
          Workflow.enqueue_good_job(workflow, next_node.workflow_level_id, jobs_to_insert)
        end
      end
    end
  end
end
