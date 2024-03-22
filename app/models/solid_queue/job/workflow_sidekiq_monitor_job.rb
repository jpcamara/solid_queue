# frozen_string_literal: true

module SolidQueue
  class Job
    class WorkflowSidekiqMonitorJob < ActiveJob::Base
      retry_on StandardError, wait: 5.seconds, attempts: 5

      self.queue_adapter = :sidekiq

      # def perform(batch, workflow)
      def perform(workflow)
        # workflow.changed_at?

        loop do
          puts "Checking the sidekiq workflow #{workflow.id}..."
          workflow.with_lock do
            return if workflow.batch_id?
            unless workflow.workflow_nodes.incomplete.any?
              workflow.update!(batch_id: 12345)

              begin
                puts "SolidQueue::Job::WorkflowMonitorJob #{workflow.id}..."
                SolidQueue::Job::WorkflowMonitorJob.perform_later(workflow)
              rescue => e
                binding.pry
                raise
              end

              return
            end

            # return if workflow.batch_id?
            # return if workflow.batch_id? && workflow.workflow_levels.where(started_at: nil).any?

            workflow.workflow_levels.where(finished_at: nil).where.not(started_at: nil).each do |workflow_level|
              if workflow.workflow_nodes.where(workflow_level_id: workflow_level.workflow_level_id).incomplete.none?
                workflow_level.update!(finished_at: Time.current)
              end
            end

            workflow.workflow_levels.where(started_at: nil).each do |next_level|
              puts "Checking the sidekiq workflow #{next_level.id}..."
              parent_level = workflow.workflow_levels.find_by!(workflow_level_id: next_level.parent_workflow_level_id)
              next if parent_level.finished_at.blank?

              Workflow.enqueue_level(workflow, next_level)
            end
          end

          sleep 1
        end
      end
    end
  end
end

# or enqueue a batch job at start of workflow
#   every child workflow batch job is part of it
#   every child workflow batch job enqueues the next level of jobs so it never finishes until they're all done
