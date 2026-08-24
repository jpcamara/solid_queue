# frozen_string_literal: true

module SolidQueue
  class BatchExecution < Execution
    self.assumable_attributes_from_job = [ :batch_id ]

    belongs_to :batch

    scope :with_finished_jobs, -> { joins(:job).merge(SolidQueue::Job.finished) }
    scope :with_failed_jobs, -> { joins(job: :failed_execution) }

    after_commit :finish_batch, on: :destroy

    class << self
      def create_all_from_jobs(jobs)
        jobs.select(&:batched?).group_by(&:batch_id).each do |batch_id, jobs_in_batch|
          # Update the counter first: inserting tracking rows takes a shared FK lock on
          # the batch row, then incrementing can deadlock concurrent MySQL adders.
          if attempt_to_update_total_jobs(batch_id, jobs_in_batch)
            super jobs_in_batch
          else
            raise Batch::AlreadyFinished, "Can't add jobs into an already finished batch"
          end
        end
      end

      # Shared by the tracking row's own destroy callback and by a finishing
      # job, which deletes its row by key and checks from its own after_commit.
      def finish_batch_for(batch_id)
        # Every finishing job asks whether it was the last one, and almost never
        # is. Asking the cheap question first means the batch row is only read
        # for the job that actually finishes the batch. #finish asks it again, so
        # this decides nothing on its own.
        #
        # Looking from the newest row backwards, because a batch drains roughly
        # in id order: the rows still outstanding are the ones at the end, while
        # the beginning of the range is whatever the finished jobs left behind.
        return if where(batch_id: batch_id).order(id: :desc).pick(:id)

        # Skip the serialized callback and metadata columns on this hot path
        if batch = Batch.select(:id, :finished_at, :enqueued_at).find_by(id: batch_id)
          batch.finish
        end
      end

      private
        def attempt_to_update_total_jobs(batch_id, jobs)
          new_jobs_count = count_new_jobs_among(jobs)
          updated = SolidQueue::Batch.where(id: batch_id).unfinished.update_all([ "total_jobs = total_jobs + ?", new_jobs_count ])
          updated > 0
        end

        # A job that has executed before was already counted when it first joined
        # the batch: retries keep their active_job_id and batch across re-enqueues.
        # This might undercount jobs whose retries switch to another batch, but that
        # should be a rare enough case. The counter is used only for report/info, so
        # we favour simplicity here
        def count_new_jobs_among(jobs)
          jobs.reject { |job| job.arguments["executions"].to_i > 0 }.map(&:active_job_id).uniq.size
        end
    end

    private
      def finish_batch
        self.class.finish_batch_for(batch_id)
      end
  end
end
