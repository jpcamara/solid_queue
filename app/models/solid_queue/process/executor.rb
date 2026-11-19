# frozen_string_literal: true

module SolidQueue
  class Process
    module Executor
      extend ActiveSupport::Concern

      included do
        has_many :claimed_executions

        after_destroy :release_all_claimed_executions
      end

      def fail_all_claimed_executions_with(error)
        if claims_executions?
          if (unstarted = unstarted_claimed_execution_ids).any?
            claimed_executions.where(id: unstarted).release_all
          end

          claimed_executions.fail_all_with(error)
        end
      end

      def release_all_claimed_executions
        if claims_executions?
          claimed_executions.release_all
        end
      end

      private
        def claims_executions?
          kind == "Worker"
        end

        # A worker that prefetches starts its jobs in the order of their claimed executions'
        # ids, and never runs more of them at once than the size of its pool, so the ones
        # beyond that, in id order, haven't started: they can't have caused the worker to
        # die, so they go back to their queues instead of failing
        def unstarted_claimed_execution_ids
          if metadata["prefetch"].to_i > 0 && (pool_size = metadata["pool_size"].to_i).positive?
            claimed_executions.order(:id).pluck(:id).drop(pool_size)
          else
            []
          end
        end
    end
  end
end
