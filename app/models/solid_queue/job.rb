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

        def wrap_enqueue_errors
          yield
        rescue => e
          raise unless e.is_a?(ActiveRecord::ActiveRecordError) ||
            (defined?(SQLite3::Exception) && e.is_a?(SQLite3::Exception)) ||
            (defined?(Mysql2::Error) && e.is_a?(Mysql2::Error)) ||
            (defined?(PG::Error) && e.is_a?(PG::Error))

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
        def single_statement_enqueue(active_job)
          now = Time.now
          scheduled_at = active_job.scheduled_at
          return nil if scheduled_at && scheduled_at > now
          return nil if active_job.respond_to?(:concurrency_key) && active_job.concurrency_key
          return nil if active_job.respond_to?(:batch_id) && active_job.batch_id

          now_string = fast_enqueue_timestamp(now)
          attributes = {
            "queue_name" => active_job.queue_name || DEFAULT_QUEUE_NAME,
            "class_name" => active_job.class.name,
            "arguments" => JSON.dump(active_job.serialize),
            "priority" => active_job.priority || DEFAULT_PRIORITY,
            "active_job_id" => active_job.job_id,
            "scheduled_at" => scheduled_at
          }

          id = wrap_enqueue_errors do
            case connection.adapter_name
            when "PostgreSQL" then pg_fast_enqueue(attributes, now_string)
            when "SQLite" then sqlite_fast_enqueue(attributes, now_string)
            when /mysql/i then mysql_fast_enqueue(attributes, now_string)
            end
          end
          return nil unless id

          instantiate(attributes.merge(
            "id" => id, "finished_at" => nil, "concurrency_key" => nil,
            "created_at" => now_string, "updated_at" => now_string
          ))
        end

        public

        # The database timestamp format Active Record uses, with the
        # formatted prefix reused within the same second. A concurrently
        # written cache entry is valid for its own second either way.
        def fast_enqueue_timestamp(now) # :nodoc:
          utc = now.getutc
          sec = utc.to_i
          cached_sec, prefix = @fast_enqueue_ts_cache

          unless sec == cached_sec
            prefix = utc.strftime("%Y-%m-%d %H:%M:%S.")
            @fast_enqueue_ts_cache = [ sec, prefix ].freeze
          end

          format("%s%06d", prefix, utc.usec)
        end

        private

        PG_ENQUEUE_SQL = <<~SQL
          WITH job AS (
            INSERT INTO solid_queue_jobs (queue_name, class_name, arguments, priority, active_job_id, scheduled_at, created_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $7)
            RETURNING id
          )
          INSERT INTO solid_queue_ready_executions (job_id, queue_name, priority, created_at)
          SELECT id, $1, $4, $7 FROM job
          RETURNING job_id
        SQL

        # Prepared once per connection and executed raw on the caller's own
        # connection: a single atomic statement that joins any open
        # transaction and autocommits durably otherwise
        def pg_fast_enqueue(attributes, now_string)
          conn = connection
          conn.materialize_transactions
          raw = conn.raw_connection

          unless conn.instance_variable_get(:@sq_enqueue_prepared)
            raw.prepare("sq_fast_enqueue", PG_ENQUEUE_SQL)
            conn.instance_variable_set(:@sq_enqueue_prepared, true)
          end

          result = raw.exec_prepared("sq_fast_enqueue", [
            attributes["queue_name"],
            attributes["class_name"],
            attributes["arguments"],
            attributes["priority"],
            attributes["active_job_id"],
            attributes["scheduled_at"] && conn.quoted_date(attributes["scheduled_at"]),
            now_string
          ])
          result.ntuples == 1 ? result.getvalue(0, 0).to_i : nil
        end

        def sqlite_fast_enqueue(attributes, now_string)
          conn = connection
          prepared = conn.instance_variable_get(:@sq_prepared_enqueue) || conn.instance_variable_set(:@sq_prepared_enqueue, {})
          job_stmt = prepared[:job] ||= conn.raw_connection.prepare(
            "INSERT INTO solid_queue_jobs (queue_name, class_name, arguments, priority, active_job_id, scheduled_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
          )
          ready_stmt = prepared[:ready] ||= conn.raw_connection.prepare(
            "INSERT INTO solid_queue_ready_executions (job_id, queue_name, priority, created_at) VALUES (?, ?, ?, ?)"
          )
          begin_stmt = prepared[:begin] ||= conn.raw_connection.prepare("BEGIN IMMEDIATE")
          commit_stmt = prepared[:commit] ||= conn.raw_connection.prepare("COMMIT")

          now = now_string
          scheduled = attributes["scheduled_at"] && conn.quoted_date(attributes["scheduled_at"])
          id = nil
          SolidQueue::SqliteWriterFunnel.acquire(connection_pool) do
            if conn.transaction_open?
              transaction do
                # Raw statements bypass Active Record, which otherwise defers
                # BEGIN until its own first statement — materialize so these
                # writes are inside the transaction they appear to be in
                conn.materialize_transactions
                id = sqlite_fast_insert(conn, job_stmt, ready_stmt, attributes, scheduled, now)
              end
            else
              raw = conn.raw_connection
              begin
                begin_stmt.execute
                id = sqlite_fast_insert(conn, job_stmt, ready_stmt, attributes, scheduled, now)
                commit_stmt.execute
              rescue Exception
                begin raw.execute("ROLLBACK"); rescue SQLite3::Exception; end
                raise
              end
            end
          end
          id
        end

        def sqlite_fast_insert(conn, job_stmt, ready_stmt, attributes, scheduled, now)
          job_stmt.execute(
            attributes["queue_name"], attributes["class_name"], attributes["arguments"],
            attributes["priority"], attributes["active_job_id"], scheduled, now, now
          ).to_a
          id = conn.raw_connection.last_insert_row_id
          ready_stmt.execute(id, attributes["queue_name"], attributes["priority"], now).to_a
          id
        end

        # Routed through the enqueue coordinator: concurrent enqueuers share
        # one batched insert transaction (each still returning only after
        # that durable commit), and a lone enqueuer is simply a batch of one.
        # Only used outside caller transactions, which the regular path serves.
        def mysql_fast_enqueue(attributes, now_string)
          # A thread with no leased connection has no open transaction —
          # checking through active_connection avoids leasing a pool
          # connection to every concurrent enqueuer for the wait's duration
          return nil if connection_pool.active_connection&.transaction_open?

          scheduled = attributes["scheduled_at"] && attributes["scheduled_at"].getutc.strftime("%Y-%m-%d %H:%M:%S.%6N")
          EnqueueCoordinator.enqueue(attributes, scheduled)
        end

        public

        # Each thread owns its client: concurrent enqueuers must commit
        # concurrently so the database can group their fsyncs — a shared
        # serialized client was measured collapsing 24-thread throughput to
        # a tenth of the regular path on real-fsync hardware.
        def fast_enqueue_mysql_client # :nodoc:
          Thread.current[:sq_enqueue_mysql_client] ||= begin
            config = connection_pool.db_config.configuration_hash
            Mysql2::Client.new(config.merge(flags: Mysql2::Client::MULTI_STATEMENTS))
          end
        end

        private

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
