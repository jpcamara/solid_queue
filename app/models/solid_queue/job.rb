# frozen_string_literal: true

module SolidQueue
  class Job < Record
    class EnqueueError < StandardError; end

    # Raised when a job's class can't be resolved anymore, typically because it
    # was renamed or removed in a deploy while jobs referencing it were in
    # flight. It subclasses NameError, which is what resolving the class raises.
    class ClassMissingError < NameError
      def self.for(job)
        new("Job class #{job.class_name.inspect} could not be resolved")
      end
    end

    include Executable, Clearable, Recurrable, Batchable
    include ReadyOnInsert

    serialize :arguments, coder: JSON

    class << self
      def enqueue_all(active_jobs)
        # Bulk enqueues bypass ActiveJob#enqueue, so batch membership is captured here
        current_batch_id = Batch.current_batch_id

        active_jobs.each do |job|
          job.scheduled_at ||= Time.current
          job.batch_id = current_batch_id || job.batch_id
        end
        active_jobs_by_job_id = active_jobs.index_by(&:job_id)

        transaction do
          inserted = without_discarded_on_enqueue(active_jobs)
          next if inserted.empty?

          database_adapter.enqueue_all(inserted).each do |enqueued_job|
            active_jobs_by_job_id[enqueued_job.active_job_id].provider_job_id = enqueued_job.id
            active_jobs_by_job_id[enqueued_job.active_job_id].successfully_enqueued = true
          end
        end

        active_jobs.count(&:successfully_enqueued?)
      end

      def enqueue(active_job, scheduled_at: Time.current)
        active_job.scheduled_at = scheduled_at

        create_from_active_job(active_job).tap do |enqueued_job|
          active_job.provider_job_id = enqueued_job.id if enqueued_job.persisted?
          active_job.successfully_enqueued = enqueued_job.persisted?
        end
      end

      # The bulk enqueue that works on every database, in the caller's
      # transaction. DatabaseAdapters::Base#enqueue_all runs it.
      def create_all_and_prepare_for_execution(active_jobs)
        prepare_all_for_execution(create_all_from_active_jobs(active_jobs))
      end

      # Inserts the rows given by attributes_from_active_job, and returns
      # their jobs.
      def create_all_from_rows(job_rows)
        insert_all(job_rows)
        where(active_job_id: job_rows.map { |attributes| attributes[:active_job_id] }).order(id: :asc)
      end

      def attributes_from_active_job(active_job)
        {
          queue_name: active_job.queue_name || DEFAULT_QUEUE_NAME,
          active_job_id: active_job.job_id,
          priority: active_job.priority || DEFAULT_PRIORITY,
          scheduled_at: active_job.scheduled_at,
          class_name: active_job.class.name,
          arguments: active_job.serialize,
          concurrency_key: active_job.concurrency_key
        }.tap do |attributes|
          attributes[:batch_id] = active_job.batch_id if Batch.migrated?
        end
      end

      private
        DEFAULT_PRIORITY = 0
        DEFAULT_QUEUE_NAME = "default"

        def create_from_active_job(active_job)
          attributes = attributes_from_active_job(active_job)
          if active_job.concurrency_max_blocked && (job = new(**attributes)).discardable_on_enqueue?
            # Counted into its batch, as a job discarded after its insert is
            BatchExecution.count_into_batches([ job ])
            job
          else
            create!(**attributes)
          end
        rescue ActiveRecord::ActiveRecordError => e
          enqueue_error = EnqueueError.new("#{e.class.name}: #{e.message}").tap do |error|
            error.set_backtrace e.backtrace
          end
          raise enqueue_error
        end

        # The jobs to insert, leaving out those discarded before their insert,
        # which are counted into their batches unless one of the same Active
        # Job is inserted. Nothing's inserted until they're all checked, so
        # jobs of one class on one key are checked once.
        def without_discarded_on_enqueue(active_jobs)
          checked = {}
          discarded = active_jobs.select(&:concurrency_max_blocked).filter_map do |active_job|
            job = new(**attributes_from_active_job(active_job))
            discardable = checked.fetch([ job.class_name, job.concurrency_key, job.due? ]) { |check| checked[check] = job.discardable_on_enqueue? }
            [ active_job, job ] if discardable
          end.to_h
          return active_jobs if discarded.empty?

          kept = active_jobs - discarded.keys
          kept_ids = kept.map(&:job_id).to_set
          BatchExecution.count_into_batches(discarded.values.reject { |job| kept_ids.include?(job.active_job_id) })
          kept
        end

        def create_all_from_active_jobs(active_jobs)
          create_all_from_rows active_jobs.map { |job| attributes_from_active_job(job) }
        end
    end
  end
end
