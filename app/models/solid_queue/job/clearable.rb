# frozen_string_literal: true

module SolidQueue
  class Job
    module Clearable
      extend ActiveSupport::Concern

      included do
        scope :clearable, ->(finished_before: SolidQueue.clear_finished_jobs_after.ago, class_name: nil) { where.not(finished_at: nil).where(finished_at: ...finished_before).where(class_name.present? ? { class_name: class_name } : {}) }
      end

      class_methods do
        def clear_finished_in_batches(batch_size: 500, finished_before: SolidQueue.clear_finished_jobs_after.ago, class_name: nil, sleep_between_batches: 0)
          database_adapter.clear_finished(batch_size:, finished_before:, class_name:, sleep_between_batches:) do
            loop do
              records_deleted = clearable(finished_before: finished_before, class_name: class_name).limit(batch_size).delete_all
              sleep(sleep_between_batches) if sleep_between_batches > 0
              break if records_deleted == 0
            end
          end
        end
      end
    end
  end
end
