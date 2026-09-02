# frozen_string_literal: true

module SolidQueue
  class Job < Record
    class EnqueueError < StandardError; end

    include Executable, Clearable, Recurrable, Batchable

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
          jobs = create_all_from_active_jobs(active_jobs)
          prepare_all_for_execution(jobs).tap do |enqueued_jobs|
            enqueued_jobs.each do |enqueued_job|
              active_jobs_by_job_id[enqueued_job.active_job_id].provider_job_id = enqueued_job.id
              active_jobs_by_job_id[enqueued_job.active_job_id].successfully_enqueued = true
            end
          end
        end

        active_jobs.count(&:successfully_enqueued?)
      end

      def enqueue(active_job, scheduled_at: Time.current)
        active_job.scheduled_at = scheduled_at

        job = single_statement_enqueue(active_job) || create_from_active_job(active_job)
        job.tap do |enqueued_job|
          active_job.provider_job_id = enqueued_job.id if enqueued_job.persisted?
          active_job.successfully_enqueued = enqueued_job.persisted?
        end
      end

      private
        DEFAULT_PRIORITY = 0
        DEFAULT_QUEUE_NAME = "default"

        def create_from_active_job(active_job)
          wrap_enqueue_errors do
            create!(**attributes_from_active_job(active_job))
          end
        end

        public

        # Memoized from pool config: reading it through a live connection
        # would lease one per enqueuing thread just to branch
        def fast_enqueue_adapter # :nodoc:
          @fast_enqueue_adapter ||= case connection_pool.db_config.adapter
          when "postgresql" then :postgresql
          when /sqlite/ then :sqlite
          when /mysql/ then :mysql
          else :other
          end
        end

        private

        def wrap_enqueue_errors
          yield
        rescue ActiveRecord::ActiveRecordError => e
          enqueue_error = EnqueueError.new("#{e.class.name}: #{e.message}").tap do |error|
            error.set_backtrace e.backtrace
          end
          raise enqueue_error
        end

        # A plain, immediate, unbatched job becomes exactly the same two rows
        # the regular path creates, written in one transaction without model
        # ceremony — on the caller's own connection, so surrounding
        # transactions and rollbacks behave identically. Anything else (or an
        # unrecognized adapter) declines and takes the regular path.
        # A plain, immediate, unbatched job enqueued outside any caller
        # transaction goes through the enqueue coordinator: the same two rows
        # the regular path creates, written with the bulk insert API in one
        # transaction that concurrent enqueuers share. Everything else takes
        # the regular path, including callers inside transactions, whose
        # writes must ride their own connection.
        def single_statement_enqueue(active_job)
          now = Time.now
          scheduled_at = active_job.scheduled_at
          return nil if scheduled_at && scheduled_at > now
          return nil if active_job.respond_to?(:concurrency_key) && active_job.concurrency_key
          return nil if active_job.respond_to?(:batch_id) && active_job.batch_id
          return nil if fast_enqueue_adapter == :other
          return nil if connection_pool.active_connection&.transaction_open?

          attributes = {
            "queue_name" => active_job.queue_name || DEFAULT_QUEUE_NAME,
            "class_name" => active_job.class.name,
            "arguments" => active_job.serialize,
            "priority" => active_job.priority || DEFAULT_PRIORITY,
            "active_job_id" => active_job.job_id,
            "scheduled_at" => scheduled_at
          }

          id = wrap_enqueue_errors do
            EnqueueCoordinator.enqueue(attributes, scheduled_at)
          end
          return nil unless id

          # instantiate expects database form, so the arguments hash goes in
          # the way the JSON coder stored it
          instantiate(attributes.merge(
            "id" => id, "arguments" => JSON.dump(attributes["arguments"]),
            "finished_at" => nil, "concurrency_key" => nil,
            "created_at" => now, "updated_at" => now
          ))
        end

        def create_all_from_active_jobs(active_jobs)
          job_rows = active_jobs.map { |job| attributes_from_active_job(job) }
          insert_all(job_rows)
          where(active_job_id: active_jobs.map(&:job_id)).order(id: :asc)
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
    end
  end
end
