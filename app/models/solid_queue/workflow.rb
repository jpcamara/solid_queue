# frozen_string_literal: true

require "tsort"
require "after_commit_everywhere"

module SolidQueue
  class Workflow < Record
    belongs_to :job_batch, foreign_key: :batch_id, optional: true
    has_many :workflow_nodes, foreign_key: :workflow_id, dependent: :destroy

    class TopologicalHash < Hash
      include TSort

      alias tsort_each_node each_key

      def tsort_each_child(node, &block)
        fetch(node).each(&block)
      end
    end

    # TODO:
    # Could we just have one batch for the whole workflow
    #  it has every job in it, but one of those jobs checks the batch, then re-enqueues for a second later
    #    and it can handle managing the levels each second
    #    and we mark a level as finished so we can query less
    #  how do we handle things on the same level with different rules? still an issue

    class << self
      def current_workflow
        ActiveSupport::IsolatedExecutionState[:workflow]
      end

      def enqueue
        transaction do
          workflow = create!

          workflow.with_context { yield workflow }

          # dependencies = workflow.built_levels.values.flatten
          # t_hash = TopologicalHash.new
          # dependencies.each do |node|
          #   t_hash[node.workflow_level_id] ||= []
          #   if node.parent_workflow_level_id.present?
          #     t_hash[node.workflow_level_id] << node.parent_workflow_level_id
          #   end
          # end
          # t_hash.sort # validates the graph is acyclic

          SolidQueue::WorkflowNode.insert_all workflow.built_nodes.map { |wn|
            wn.attributes.except("id").merge("created_at" => Time.current, "updated_at" => Time.current)
          }

          workflow.workflow_nodes.where(parent_workflow_level_id: nil).each do |workflow_node|
            jobs_to_insert = [prep_node(workflow_node)]

            # jobs_to_insert = prep_level(workflow, workflow_node.workflow_level_id)

            # Sidekiq
            # enqueue_level(workflow, workflow_node.workflow_level_id)

            # Sidekiq Pro happens in after commit
            # enqueue_sidekiq_pro(workflow, workflow_node.workflow_level_id, jobs_to_insert)

            # Only actual SolidQueue specific code
            enqueue_solid_queue(workflow, workflow_node.workflow_level_id, jobs_to_insert)

            # GoodJob
            # enqueue_good_job(workflow, workflow_node.workflow_level_id, jobs_to_insert)
          end

          # Sidekiq
          # AfterCommitEverywhere.after_commit do
          #   SolidQueue::Job::WorkflowSidekiqMonitorJob.set(wait: 1.second).perform_later(workflow)
          # end

          workflow
        end
      rescue => e
        puts "Error: #{e.message}"
        puts e.backtrace
        raise
      end

      def parent_level_id
        ActiveSupport::IsolatedExecutionState[:parent_level_id]
      end

      def prep_level(workflow, workflow_level_id)
        # puts "prepping level #{workflow_level_id}"
        level_nodes = workflow.workflow_nodes.where(workflow_level_id: workflow_level_id)

        jobs_to_insert = []
        level_nodes.each do |level_node|
          jobs_to_insert << prep_node(level_node)
        end

        jobs_to_insert.compact
      end

      def prep_node(workflow_node)
        return if workflow_node.started_at.present? # should group by level first instead of iterating each on level

        workflow_node.update!(started_at: Time.current)
        ActiveJob::Base.deserialize(workflow_node.active_job).tap do |active_job|
          active_job.send(:deserialize_arguments_if_needed)
        end
      end

      def enqueue_good_job(workflow, workflow_level_id, jobs_to_insert)
        workflow.with_context do
          GoodJob::Batch.enqueue(
            jobs_to_insert,
            on_finish: ::SolidQueue::Job::WorkflowGoodJobCallbackJob,
            workflow: workflow,
            workflow_level_id: workflow_level_id
            # workflow_level: workflow_level
          )
        end
      end

      def enqueue_solid_queue(workflow, workflow_level_id, jobs_to_insert)
        workflow.with_context do
          JobBatch.enqueue(on_finish: SolidQueue::Job::WorkflowCallbackJob.new(workflow, workflow_level_id)) do
            ActiveJob.perform_all_later(jobs_to_insert) if jobs_to_insert.any?
          end
        end
      end

      def enqueue_sidekiq_pro(workflow, workflow_level_id, jobs_to_insert)
        AfterCommitEverywhere.after_commit do
          workflow.with_context do
            # Sidekiq Pro
            batch = Sidekiq::Batch.new
            %i[success death].each do |event|
              batch.on(
                event,
                SolidQueue::Job::WorkflowSidekiqBatchCallback,
                workflow_id: workflow.id,
                workflow_level_id: workflow_level_id
                # workflow_level_id: workflow_level.workflow_level_id
              )
            end
            batch.jobs do
              ActiveJob.perform_all_later(jobs_to_insert) if jobs_to_insert.any?
            end

            # If rails >= 7.1
            # ActiveJob.perform_all_later(jobs_to_insert) if jobs_to_insert.any?
            # If rails < 7.1
            # jobs_to_insert.group_by(&:queue_adapter).each do |queue_adapter, jobs|
            #   jobs.each do |job|
            #     if job.scheduled_at
            #       queue_adapter.enqueue_at(job, job.scheduled_at.to_f)
            #     else
            #       queue_adapter.enqueue(job)
            #     end
            #   end
            # end
          end
        end
      end
    end

    attr_reader :built_nodes, :built_levels

    def with_context
      begin
        was = ActiveSupport::IsolatedExecutionState[:workflow]
        ActiveSupport::IsolatedExecutionState[:workflow] = self
        yield self
      ensure
        ActiveSupport::IsolatedExecutionState[:workflow] = was
      end
    end

    def run(*active_jobs)
      @built_nodes ||= []
      @built_levels ||= []
      workflow_level_id = SecureRandom.uuid

      if Workflow.parent_level_id.blank?
        # @built_levels << workflow_levels.build(
        #   workflow: self,
        #   workflow_level_id: workflow_level_id
        # )

        active_jobs.each do |active_job|
          @built_nodes << workflow_nodes.build(
            workflow: self,
            active_job_id: active_job.job_id,
            active_job: active_job.serialize,
            workflow_level_id: workflow_level_id
          )
        end

        begin
          was = ActiveSupport::IsolatedExecutionState[:parent_level_id]
          ActiveSupport::IsolatedExecutionState[:parent_level_id] = workflow_level_id
          yield if block_given?
        ensure
          ActiveSupport::IsolatedExecutionState[:parent_level_id] = was
        end


      elsif Workflow.parent_level_id.present?
        # @built_levels << workflow_levels.build(
        #   workflow: self,
        #   workflow_level_id: workflow_level_id,
        #   parent_workflow_level_id: Workflow.parent_level_id
        # )

        active_jobs.each do |active_job|
          @built_nodes << workflow_nodes.build(
            workflow: self,
            active_job_id: active_job.job_id,
            active_job: active_job.serialize,
            workflow_level_id: workflow_level_id,
            parent_workflow_level_id: Workflow.parent_level_id
          )
        end

        begin
          was = ActiveSupport::IsolatedExecutionState[:parent_level_id]
          ActiveSupport::IsolatedExecutionState[:parent_level_id] = workflow_level_id
          yield if block_given?
        ensure
          ActiveSupport::IsolatedExecutionState[:parent_level_id] = was
        end
      end

      active_jobs
    end
  end
end
