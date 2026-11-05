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

        create_from_active_job(active_job).tap do |enqueued_job|
          active_job.provider_job_id = enqueued_job.id if enqueued_job.persisted?
          active_job.successfully_enqueued = enqueued_job.persisted?
        end
      end

      private
        DEFAULT_PRIORITY = 0
        DEFAULT_QUEUE_NAME = "default"

        def create_from_active_job(active_job)
          attributes = attributes_from_active_job(active_job)

          if ready_in_one_statement?(attributes) then create_ready(attributes)
          else
            create!(**attributes)
          end
        rescue ActiveRecord::ActiveRecordError => e
          enqueue_error = EnqueueError.new("#{e.class.name}: #{e.message}").tap do |error|
            error.set_backtrace e.backtrace
          end
          raise enqueue_error
        end

        # A job that's due, without concurrency limits, only needs its ready
        # execution, and a tracking row if it's in a batch that's already
        # counted and locked in this transaction (see BatchExecution.counting_jobs).
        # PostgreSQL can insert them all in one statement.
        def ready_in_one_statement?(attributes)
          attributes[:concurrency_key].nil? && (attributes[:batch_id].nil? || BatchExecution.counted?(attributes[:batch_id])) &&
            (attributes[:scheduled_at].nil? || attributes[:scheduled_at] <= Time.current) &&
            connection_pool.with_connection { |connection| connection.adapter_name == "PostgreSQL" }
        end

        def create_ready(attributes)
          now = Time.current
          attributes = attributes.merge(created_at: now, updated_at: now).compact
          binds = attributes.map { |name, value| ActiveRecord::Relation::QueryAttribute.new(name.to_s, value, type_for_attribute(name)) }
          tracking_row = if attributes[:batch_id]
            ", tracked AS (INSERT INTO #{BatchExecution.quoted_table_name} (job_id, batch_id, created_at) SELECT id, batch_id, created_at FROM job)"
          end

          connection_pool.with_connection do |connection|
            columns, ready_columns = [ attributes.keys, ReadyExecution.assumable_attributes_from_job ].map do |names|
              names.map { |name| connection.quote_column_name(name) }
            end

            # exec_query, as a write, clears the query cache and is never served from it
            instantiate(connection.exec_query(<<~SQL.squish, "#{name} Create", binds).first)
              WITH job AS (
                INSERT INTO #{quoted_table_name} (#{columns.join(", ")})
                VALUES (#{Array.new(binds.size) { |i| "$#{i + 1}" }.join(", ")})
                RETURNING *
              ), ready AS (
                INSERT INTO #{ReadyExecution.quoted_table_name} (job_id, #{ready_columns.join(", ")}, created_at)
                SELECT id, #{ready_columns.join(", ")}, created_at FROM job
              )#{tracking_row}
              SELECT * FROM job
            SQL
          end.tap { BatchExecution.count_added(attributes) if attributes[:batch_id] }
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
