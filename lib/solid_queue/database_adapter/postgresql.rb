# frozen_string_literal: true

module SolidQueue
  class DatabaseAdapter
    class Postgresql < DatabaseAdapter
      # The same rows, locks and atomicity as the regular path in one
      # statement: candidates locked with SKIP LOCKED, moved into claimed
      # executions and deleted from ready, with the job row hydrated
      # alongside so execution doesn't need to load it.
      def claim(queue_relation, process_id, limit)
        return [] if limit <= 0

        candidates_sql = queue_relation.ordered.limit(limit).non_blocking_lock.select(:id, :job_id).to_sql
        result = ReadyExecution.connection.exec_query(<<~SQL, "SolidQueue::ClaimedExecution Claim", [ bind(ClaimedExecution, :process_id, process_id) ])
          WITH candidates AS (#{candidates_sql}),
          deleted AS (
            DELETE FROM solid_queue_ready_executions WHERE id IN (SELECT id FROM candidates)
          ),
          claimed AS (
            INSERT INTO solid_queue_claimed_executions (job_id, process_id, created_at)
            SELECT job_id, $1, now() FROM candidates
            RETURNING id, job_id, process_id, created_at
          )
          SELECT claimed.id AS claimed_id, claimed.job_id AS claimed_job_id,
                 claimed.process_id AS claimed_process_id, claimed.created_at AS claimed_created_at,
                 #{ReadyExecution.hydration_columns}
          FROM claimed INNER JOIN solid_queue_jobs jobs ON jobs.id = claimed.job_id
        SQL

        result.rows.map do |row|
          attrs = result.columns.zip(row).to_h
          execution = ClaimedExecution.instantiate(
            "id" => attrs["claimed_id"], "job_id" => attrs["claimed_job_id"],
            "process_id" => attrs["claimed_process_id"], "created_at" => attrs["claimed_created_at"]
          )
          job = Job.instantiate(attrs.slice(*Job.column_names))
          execution.association(:job).target = job
          execution
        end
      end

      # One atomic statement: the delete and the finish share a snapshot and
      # a commit without transaction round trips
      def flush_completions(job_ids)
        Job.connection.exec_update(<<~SQL)
          WITH deleted AS (
            DELETE FROM solid_queue_claimed_executions WHERE job_id IN (#{job_ids.join(",")}) RETURNING job_id
          )
          UPDATE solid_queue_jobs SET finished_at = now()
          WHERE id IN (SELECT job_id FROM deleted)
        SQL
      end

      # One atomic statement, one round trip, one implicit commit: the job
      # rows and their ready executions land together, so a serial caller
      # pays for the commit and little else. Values are bind parameters of
      # an unnamed statement, which transaction-pooling proxies pass
      # through untouched: a lone job binds its eight values directly,
      # while a batch binds one array per column and unnests them, so a
      # batch of any size is still exactly eight parameters.
      JOB_COLUMNS = "queue_name, class_name, arguments, priority, active_job_id, scheduled_at, created_at, updated_at"
      READY_FROM_JOBS = <<~SQL.squish
        ready AS (
          INSERT INTO solid_queue_ready_executions (job_id, queue_name, priority, created_at)
          SELECT id, queue_name, priority, created_at FROM jobs
        )
        SELECT id FROM jobs ORDER BY id
      SQL
      ENQUEUE_ONE_SQL = <<~SQL.squish
        WITH jobs AS (
          INSERT INTO solid_queue_jobs (#{JOB_COLUMNS})
          VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
          RETURNING id, queue_name, priority, created_at
        ), #{READY_FROM_JOBS}
      SQL
      ENQUEUE_MANY_SQL = <<~SQL.squish
        WITH jobs AS (
          INSERT INTO solid_queue_jobs (#{JOB_COLUMNS})
          SELECT * FROM unnest($1::varchar[], $2::varchar[], $3::text[], $4::integer[], $5::varchar[], $6::timestamp[], $7::timestamp[], $8::timestamp[])
          RETURNING id, queue_name, priority, created_at
        ), #{READY_FROM_JOBS}
      SQL

      def write_enqueue_batch(job_rows, now)
        if job_rows.one?
          row = job_rows.first
          binds = [
            bind(Job, :queue_name, row[:queue_name]), bind(Job, :class_name, row[:class_name]),
            bind(Job, :arguments, row[:arguments]), bind(Job, :priority, row[:priority]),
            bind(Job, :active_job_id, row[:active_job_id]), bind(Job, :scheduled_at, row[:scheduled_at]),
            bind(Job, :created_at, now), bind(Job, :updated_at, now)
          ]
          return Job.connection.exec_query(ENQUEUE_ONE_SQL, "SolidQueue::Job Create", binds).rows.map(&:first)
        end

        connection = Job.connection
        arguments_type = Job.type_for_attribute("arguments")
        stamp = connection.quoted_date(now)
        binds = [
          array_bind(:queue_name, job_rows.map { |row| row[:queue_name] }),
          array_bind(:class_name, job_rows.map { |row| row[:class_name] }),
          array_bind(:arguments, job_rows.map { |row| arguments_type.serialize(row[:arguments]) }),
          array_bind(:priority, job_rows.map { |row| row[:priority] }, integer_array),
          array_bind(:active_job_id, job_rows.map { |row| row[:active_job_id] }),
          array_bind(:scheduled_at, job_rows.map { |row| row[:scheduled_at] && connection.quoted_date(row[:scheduled_at]) }),
          array_bind(:created_at, Array.new(job_rows.size, stamp)),
          array_bind(:updated_at, Array.new(job_rows.size, stamp))
        ]

        connection.exec_query(ENQUEUE_MANY_SQL, "SolidQueue::Job Create", binds).rows.map(&:first)
      end

      private
        def array_bind(column, values, type = string_array)
          ActiveRecord::Relation::QueryAttribute.new(column.to_s, values, type)
        end

        # The adapter's array types exist once a PostgreSQL connection has
        # been established, so they are resolved on first use rather than
        # when this class is loaded
        def string_array
          @string_array ||= ActiveRecord::ConnectionAdapters::PostgreSQL::OID::Array.new(ActiveModel::Type::String.new)
        end

        def integer_array
          @integer_array ||= ActiveRecord::ConnectionAdapters::PostgreSQL::OID::Array.new(ActiveModel::Type::Integer.new)
        end
    end
  end
end
