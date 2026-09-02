# frozen_string_literal: true

module SolidQueue
  class DatabaseAdapter
    class Sqlite < DatabaseAdapter
      # One writer at a time within the process: SQLite allows a single
      # write transaction, and letting threads queue on a mutex is cheaper
      # and fairer than colliding with the database's busy handler
      WRITE_MUTEX = Mutex.new

      # Completions flush from a dedicated thread on single-writer databases
      def dedicated_flusher?
        true
      end

      def serialize_writes(&block)
        WRITE_MUTEX.synchronize(&block)
      end

      # Single-writer, so candidates need no row locks: read them joined
      # with their jobs in one query, then move them ready -> claimed with
      # two plain statements in one serialized transaction
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

      def flush_completions(job_ids)
        serialize_writes { super }
      end

      def insert_jobs_returning_ids(job_rows)
        Job.insert_all!(job_rows)
        last = Job.connection.select_value("SELECT last_insert_rowid()").to_i
        ((last - job_rows.size + 1)..last).to_a
      end
    end
  end
end
