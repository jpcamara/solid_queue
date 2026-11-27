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

      # Makes inserted jobs with concurrency limits that are due ready, or
      # blocks or discards them, taking their slots, in the transaction it's
      # called in. The given block does it for the jobs it's given, one at a
      # time.
      def dispatch_limited(jobs)
        yield jobs
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

      # Takes a concurrency slot for the job. Returns the id of the semaphore
      # it got the slot from, or nil if none was free.
      def take_slot(job)
        Semaphore::Proxy.new(job).wait
      end

      # Gives the job's concurrency slot back. Returns whether it did.
      def give_back_slot(job)
        Semaphore::Proxy.new(job).signal
      end

      # The concurrency keys among these with a slot free, or with no
      # semaphore yet.
      def keys_with_free_slots(keys)
        semaphores = Semaphore.where(key: keys).pluck(:key, :value).to_h
        (keys - semaphores.keys) | semaphores.select { |_key, value| value > 0 }.keys
      end

      # Locks the concurrency key until the transaction ends, so callers on it
      # take turns.
      def lock_concurrency_key(key)
        Semaphore.lock.find_by(key: key)
      end

      # Whether the concurrency key has no slot free and at least count jobs
      # blocked on it. Both are read in one statement, without locking, so
      # they come from the same moment.
      def full_with_blocked?(key, count)
        full = Semaphore.where(key: key, value: ..0)
        if count.positive?
          count_th = BlockedExecution.where(concurrency_key: key).offset(count - 1).limit(1).select(1)
          full = full.where(count_th.arel.exists)
        end
        full.exists?
      end

      # Run by the dispatcher's concurrency maintenance: deletes the
      # semaphores that have expired, batch_size at a time.
      def expire_semaphores(batch_size)
        Semaphore.expired.in_batches(of: batch_size, &:delete_all)
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
