# frozen_string_literal: true

module SolidQueue
  module DatabaseAdapters
    # Runs the code in the models that works on every database. Adapters for
    # particular databases override what they can do in fewer statements.
    class Base
      # Inserts the row of a job being created with the INSERT Active Record
      # built for it, given as the block, and returns what that returns. Its
      # callbacks then make the job ready, blocked or scheduled.
      def insert_job(job, *)
        yield
      end

      # Inserts the jobs of a perform_all_later and makes each ready, blocked
      # or scheduled, in the transaction it's called in. Returns the jobs
      # enqueued.
      def enqueue_all(active_jobs)
        Job.create_all_and_prepare_for_execution(active_jobs)
      end

      # Releases a blocked execution if its job gets a concurrency slot,
      # making the job ready, and fails a job whose class doesn't load.
      def release(blocked_execution)
        blocked_execution.release_in_steps
      end

      # Gives back the concurrency slot the job holds, if any, and releases
      # the next job blocked on its concurrency key.
      def unblock_next(job)
        job.unblock_next_blocked_job_in_steps
      end

      # Makes the jobs ready, running the given block, which does it in the
      # ready executions table. The models call it for one job or for many.
      def make_ready(jobs)
        yield
      end

      # Schedules the jobs, running the given block, which does it in the
      # scheduled executions table. Returns what the block returns.
      def schedule(jobs)
        yield
      end

      # Makes up to batch_size scheduled jobs that are due ready, running the
      # given block, which takes them from the scheduled executions table.
      # Returns how many were dispatched.
      def dispatch_scheduled(batch_size)
        yield
      end

      # Claims up to limit ready executions from the queues in queue_list, in
      # their order, for the process, skipping those locked elsewhere, and
      # returns the claims.
      def claim(queue_list, process_id, limit)
        ReadyExecution.claim_from_each_queue(queue_list, limit) do |queue_relation, remaining|
          ReadyExecution.claim_in_transaction(queue_relation, process_id, remaining)
        end
      end

      # Marks the claim's job finished and deletes the claim, unless the claim
      # is already gone. Returns whether it was there.
      def finish(claimed_execution)
        claimed_execution.finalize_claim { claimed_execution.job.finished! }
      end
    end
  end
end
