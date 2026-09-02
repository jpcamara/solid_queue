# frozen_string_literal: true

module SolidQueue
  class DatabaseAdapter
    class Sqlite < DatabaseAdapter
      # One writer at a time within the process: SQLite allows a single
      # write transaction, and letting threads queue on a mutex is cheaper
      # and fairer than colliding with the database's busy handler
      WRITE_MUTEX = Mutex.new

      # Parameterized statements through Active Record's per-connection
      # statement cache. SQLite runs in-process, so there is no server
      # session for a pooler to swap out from under a prepared statement,
      # and compiling the same statement on every call was the largest cost
      # left in these paths. Id lists travel as one JSON bind through
      # json_each so a statement's shape never varies with batch size.
      INSERT_JOB = <<~SQL.squish
        INSERT INTO solid_queue_jobs (queue_name, class_name, arguments, priority, active_job_id, scheduled_at, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?) RETURNING id
      SQL
      INSERT_BATCHED_JOB = <<~SQL.squish
        INSERT INTO solid_queue_jobs (queue_name, class_name, arguments, priority, active_job_id, scheduled_at, created_at, updated_at, batch_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING id
      SQL
      INSERT_TRACKING = <<~SQL.squish
        INSERT INTO solid_queue_batch_executions (job_id, batch_id, created_at) VALUES (?, ?, ?)
      SQL
      INSERT_READY = <<~SQL.squish
        INSERT INTO solid_queue_ready_executions (job_id, queue_name, priority, created_at) VALUES (?, ?, ?, ?)
      SQL
      INSERT_CLAIMED = <<~SQL.squish
        INSERT INTO solid_queue_claimed_executions (job_id, process_id, created_at)
        SELECT value, ?, ? FROM json_each(?)
      SQL
      DELETE_READY = "DELETE FROM solid_queue_ready_executions WHERE id IN (SELECT value FROM json_each(?))"
      DELETE_CLAIMED = "DELETE FROM solid_queue_claimed_executions WHERE job_id IN (SELECT value FROM json_each(?))"
      DELETE_TRACKED = "DELETE FROM solid_queue_batch_executions WHERE job_id IN (SELECT value FROM json_each(?))"
      FINISH_JOBS = "UPDATE solid_queue_jobs SET finished_at = ? WHERE id IN (SELECT value FROM json_each(?))"

      # Completions flush from a dedicated thread on single-writer databases
      def dedicated_flusher?
        true
      end

      def serialize_writes(&block)
        WRITE_MUTEX.synchronize(&block)
      end

      # Single-writer, so candidates need no row locks: read them joined
      # with their jobs in one query, then move them ready -> claimed with
      # two cached statements in one serialized transaction
      def claim(queue_relation, process_id, limit)
        return [] if limit <= 0

        candidates_sql = queue_relation.ordered.limit(limit).select(:id, :job_id).to_sql
        result = ReadyExecution.connection.select_all(<<~SQL)
          SELECT c.id AS ready_id, #{ReadyExecution.hydration_columns}
          FROM (#{candidates_sql}) c INNER JOIN solid_queue_jobs jobs ON jobs.id = c.job_id
        SQL
        return [] if result.rows.empty?

        rows = hydrate_candidates(result, process_id)
        serialize_writes do
          ReadyExecution.transaction do
            move_to_claimed(rows, process_id)
          end
        end
        rows.map(&:last)
      end

      def flush_completions(job_ids, tracked: false)
        serialize_writes do
          Job.transaction do
            ids = json_bind(job_ids)
            execute(DELETE_CLAIMED, "SolidQueue::ClaimedExecution Destroy", [ ids ])
            execute(DELETE_TRACKED, "SolidQueue::BatchExecution Destroy", [ ids ]) if tracked
            execute(FINISH_JOBS, "SolidQueue::Job Update", [ bind(Job, :finished_at, Time.current), ids ])
          end
        end
      end

      # Round trips are function calls here, so each row goes through the
      # cached single-row statements rather than a multi-row insert whose
      # SQL would have to be built and compiled per batch
      def write_enqueue_batch(job_rows, now)
        Job.transaction do
          count_batched(job_rows)
          job_rows.map do |row|
            id = if row[:batch_id]
              execute(INSERT_BATCHED_JOB, "SolidQueue::Job Create", job_binds(row, now) << bind(Job, :batch_id, row[:batch_id])).rows.first.first
            else
              execute(INSERT_JOB, "SolidQueue::Job Create", job_binds(row, now)).rows.first.first
            end
            execute(INSERT_READY, "SolidQueue::ReadyExecution Create", [
              bind(ReadyExecution, :job_id, id), bind(ReadyExecution, :queue_name, row[:queue_name]),
              bind(ReadyExecution, :priority, row[:priority]), bind(ReadyExecution, :created_at, now)
            ])
            if row[:batch_id]
              execute(INSERT_TRACKING, "SolidQueue::BatchExecution Create", [
                bind(BatchExecution, :job_id, id), bind(BatchExecution, :batch_id, row[:batch_id]), bind(BatchExecution, :created_at, now)
              ])
            end
            id
          end
        end
      end

      private
        def move_to_claimed(rows, process_id)
          execute(INSERT_CLAIMED, "SolidQueue::ClaimedExecution Create", [
            bind(ClaimedExecution, :process_id, process_id), bind(ClaimedExecution, :created_at, Time.current),
            json_bind(rows.map { |_, execution| execution.job_id })
          ])
          execute(DELETE_READY, "SolidQueue::ReadyExecution Destroy", [ json_bind(rows.map(&:first)) ])
        end

        def execute(sql, name, binds)
          connection = Job.connection
          connection.exec_query(sql, name, binds, prepare: connection.prepared_statements?)
        end

        def job_binds(row, now)
          [
            bind(Job, :queue_name, row[:queue_name]), bind(Job, :class_name, row[:class_name]),
            bind(Job, :arguments, row[:arguments]), bind(Job, :priority, row[:priority]),
            bind(Job, :active_job_id, row[:active_job_id]), bind(Job, :scheduled_at, row[:scheduled_at]),
            bind(Job, :created_at, now), bind(Job, :updated_at, now)
          ]
        end

        def json_bind(ids)
          ActiveRecord::Relation::QueryAttribute.new("ids", JSON.dump(ids), ActiveModel::Type::String.new)
        end
    end
  end
end
