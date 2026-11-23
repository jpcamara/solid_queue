# frozen_string_literal: true

module SolidQueue
  class ReadyExecution < Execution
    scope :queued_as, ->(queue_name) { where(queue_name: queue_name) }

    assumes_attributes_from_job

    class << self
      def claim(queue_list, limit, process_id)
        QueueSelector.new(queue_list, self).scoped_relations.flat_map do |queue_relation|
          select_and_lock(queue_relation, process_id, limit).tap do |locked|
            limit -= locked.size
          end
        end
      end

      def aggregated_count_across(queue_list)
        QueueSelector.new(queue_list, self).scoped_relations.map(&:count).sum
      end

      private
        def select_and_lock(queue_relation, process_id, limit)
          return [] if limit <= 0

          database_adapter.claim(queue_relation, process_id, limit)
        end

        def discard_jobs(job_ids)
          Job.unblock_next_blocked_jobs Job.where(id: job_ids)
          super
        end
    end
  end
end
