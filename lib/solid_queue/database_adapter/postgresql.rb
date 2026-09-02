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
        result = ReadyExecution.connection.select_all(<<~SQL)
          WITH candidates AS (#{candidates_sql}),
          deleted AS (
            DELETE FROM solid_queue_ready_executions WHERE id IN (SELECT id FROM candidates)
          ),
          claimed AS (
            INSERT INTO solid_queue_claimed_executions (job_id, process_id, created_at)
            SELECT job_id, #{process_id ? ReadyExecution.connection.quote(process_id) : "NULL"}, now() FROM candidates
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
      # pays for the commit and little else
      def write_enqueue_batch(job_rows, now)
        connection = Job.connection
        arguments_type = Job.type_for_attribute("arguments")
        values = job_rows.map do |row|
          [ row[:queue_name], row[:class_name], arguments_type.serialize(row[:arguments]), row[:priority],
            row[:active_job_id], row[:scheduled_at], now, now ].map { |value| connection.quote(value) }.join(", ")
        end

        connection.select_values(<<~SQL)
          WITH jobs AS (
            INSERT INTO solid_queue_jobs (queue_name, class_name, arguments, priority, active_job_id, scheduled_at, created_at, updated_at)
            VALUES (#{values.join("), (")})
            RETURNING id, queue_name, priority, created_at
          ), ready AS (
            INSERT INTO solid_queue_ready_executions (job_id, queue_name, priority, created_at)
            SELECT id, queue_name, priority, created_at FROM jobs
          )
          SELECT id FROM jobs ORDER BY id
        SQL
      end
    end
  end
end
