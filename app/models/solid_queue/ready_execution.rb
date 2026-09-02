# frozen_string_literal: true

module SolidQueue
  class ReadyExecution < Execution
    scope :queued_as, ->(queue_name) { where(queue_name: queue_name) }

    assumes_attributes_from_job

    class << self
      def claim(queue_list, limit, process_id)
        adapter = DatabaseAdapter.resolve

        QueueSelector.new(queue_list, self).scoped_relations.flat_map do |queue_relation|
          claimed =
            if adapter.fast_paths?
              adapter.claim(queue_relation, process_id, limit).tap do |executions|
                job_ids = executions.map(&:job_id)
                SolidQueue.instrument(:claim, process_id: process_id, job_ids: job_ids,
                  claimed_job_ids: job_ids, size: executions.size)
              end
            else
              select_and_lock(queue_relation, process_id, limit).tap do |locked|
                preload_jobs(locked)
              end
            end
          limit -= claimed.size
          claimed
        end
      end

      def preload_jobs(claimed)
        return if claimed.empty?

        jobs_by_id = SolidQueue::Job.where(id: claimed.map(&:job_id)).index_by(&:id)
        claimed.each { |execution| execution.association(:job).target = jobs_by_id[execution.job_id] }
      end

      # Only the columns the execution path reads: converting and instantiating
      # unused columns is measurable client CPU at high claim rates
      def hydration_columns
        @hydration_columns ||= (%w[ id active_job_id queue_name class_name arguments priority concurrency_key batch_id ] &
          SolidQueue::Job.column_names).map { |c| "jobs.#{c}" }.join(", ")
      end




      def aggregated_count_across(queue_list)
        QueueSelector.new(queue_list, self).scoped_relations.map(&:count).sum
      end

      private
        def select_and_lock(queue_relation, process_id, limit)
          return [] if limit <= 0

          transaction do
            candidates = select_candidates(queue_relation, limit)
            lock_candidates(candidates, process_id)
          end
        end

        def select_candidates(queue_relation, limit)
          # Force query execution here with #to_a to avoid unintended FOR UPDATE query executions
          queue_relation.ordered.limit(limit).non_blocking_lock.select(:id, :job_id).to_a
        end

        def lock_candidates(executions, process_id)
          return [] if executions.none?

          SolidQueue::ClaimedExecution.claiming(executions.map(&:job_id), process_id) do |claimed|
            ids_to_delete = executions.index_by(&:job_id).values_at(*claimed.map(&:job_id)).map(&:id)
            where(id: ids_to_delete).delete_all
          end
        end


        def discard_jobs(job_ids)
          Job.release_all_concurrency_locks Job.where(id: job_ids)
          super
        end
    end
  end
end
