# frozen_string_literal: true

module SolidQueue
  class ScheduledExecution < Execution
    include Dispatching

    scope :due, -> { where(scheduled_at: ..Time.current) }
    scope :ordered, -> { order(scheduled_at: :asc, priority: :asc, job_id: :asc) }
    scope :next_batch, ->(batch_size) { due.ordered.limit(batch_size) }

    assumes_attributes_from_job :scheduled_at

    class << self
      def dispatch_next_batch(batch_size)
        database_adapter.dispatch_scheduled(batch_size) { dispatch_due(batch_size) }
      end

      # Dispatches up to batch_size due jobs, in order, only those after the
      # position (scheduled_at, priority, job_id) when given, and returns how
      # many it dispatched. Yields how many it selected, and the position of
      # the last one, if any.
      def dispatch_due(batch_size, after: nil)
        transaction do
          batch = next_batch(batch_size)
          batch = batch.where("(scheduled_at, priority, job_id) > (?, ?, ?)", *after) if after
          rows = batch.non_blocking_lock.pluck(:job_id, :scheduled_at, :priority)
          yield rows.size, rows.last&.values_at(1, 2, 0) if block_given?

          if rows.empty? then 0
          else
            SolidQueue.instrument(:dispatch_scheduled, batch_size: batch_size) do |payload|
              payload[:size] = dispatch_jobs(rows.map(&:first))
            end
          end
        end
      end
    end
  end
end
