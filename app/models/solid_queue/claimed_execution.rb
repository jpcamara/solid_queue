# frozen_string_literal: true

class SolidQueue::ClaimedExecution < SolidQueue::Execution
  belongs_to :process

  scope :orphaned, -> { where.missing(:process) }

  class Result < Struct.new(:success, :error)
    def success?
      success
    end
  end

  class << self
    # Claimed rows are identified by their unique job_id, so instances built
    # from the data just inserted work without reloading generated ids
    def instantiate_claimed(data)
      instantiate(data.transform_keys(&:to_s).merge("id" => nil, "created_at" => Time.current))
    end

    def claiming(job_ids, process_id, &block)
      job_data = Array(job_ids).collect { |job_id| { job_id: job_id, process_id: process_id } }

      SolidQueue.instrument(:claim, process_id: process_id, job_ids: job_ids) do |payload|
        insert_all!(job_data)
        job_data.map { |data| instantiate_claimed(data) }.tap do |claimed|
          block.call(claimed)

          payload[:size] = claimed.size
          payload[:claimed_job_ids] = claimed.map(&:job_id)
        end
      end
    end

    def release_all
      SolidQueue.instrument(:release_many_claimed) do |payload|
        includes(:job).tap do |executions|
          executions.each(&:release)

          payload[:size] = executions.size
        end
      end
    end

    def fail_all_with(error)
      includes(:job).tap do |executions|
        return if executions.empty?

        SolidQueue.instrument(:fail_many_claimed) do |payload|
          executions.each do |execution|
            execution.failed_with(error)
          end

          payload[:process_ids] = executions.map(&:process_id).uniq
          payload[:job_ids] = executions.map(&:job_id).uniq
          payload[:size] = executions.size
          payload[:error] = error
        end
      end
    end

    def discard_all_in_batches(*)
      raise UndiscardableError, "Can't discard jobs in progress"
    end

    def discard_all_from_jobs(*)
      raise UndiscardableError, "Can't discard jobs in progress"
    end
  end

  def perform
    result = execute

    if result.success?
      finished
    else
      failed_with(result.error)
      raise result.error
    end
  end

  def release
    SolidQueue.instrument(:release_claimed, job_id: job.id, process_id: process_id) do
      unless_already_finalized do
        job.dispatch_bypassing_concurrency_limits
      end
    end
  end

  def discard
    raise UndiscardableError, "Can't discard a job in progress"
  end

  def failed_with(error)
    finalize { job.failed_with(error) }
  end

  private
    def execute
      ActiveJob::Base.execute(job.arguments.merge("provider_job_id" => job.id))
      Result.new(true, nil)
    rescue Exception => e
      Result.new(false, e)
    end

    def finished
      if single_statement_finish?
        single_statement_finish
      else
        finalize { job.finished! }
      end
    end

    # Plain jobs on PostgreSQL: no concurrency semaphore to release, no batch
    # tracking, no preserve=false destroy — the finish collapses to one atomic
    # statement with the claimed row's deletion as the ownership guard
    def single_statement_finish?
      SolidQueue.preserve_finished_jobs? &&
        job.concurrency_key.nil? &&
        !(job.respond_to?(:batched?) && job.batched?)
    end

    def single_statement_finish
      SolidQueue::CompletionCoordinator.finish(self)
    end

    def finalize
      finalized = unless_already_finalized do
        yield
        true
      end

      # Unblock the next job outside the finalize transaction so a failure while
      # releasing the concurrency lock or dispatching the next job can't roll back
      # a job that already finished or failed. Only the actor that owned and
      # finalized the claim gets here, so the lock is released exactly once.
      job.unblock_next_blocked_job if finalized
    end

    def unless_already_finalized
      transaction do
        return false unless self.class.unscoped.where(job_id: job_id).delete_all == 1

        yield
      end
    end
end
