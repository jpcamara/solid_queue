# frozen_string_literal: true

module SolidQueue
  class DatabaseAdapter
    class Mysql < DatabaseAdapter
      # Same rows and locks as the regular path: candidates locked with
      # SKIP LOCKED (only the ready rows, via FOR UPDATE OF), jobs read in
      # the same query, then moved ready -> claimed with bulk writes in the
      # same transaction. READ COMMITTED skips the gap locks REPEATABLE READ
      # adds to the ordered range scan, which serialize concurrent claimers
      # against enqueuers on the index head.
      def claim(queue_relation, process_id, limit)
        return [] if limit <= 0

        conditions = queue_relation.where_clause.any? ? "WHERE #{queue_relation.where_clause.ast.to_sql}" : ""
        select_sql = <<~SQL
          SELECT re.id AS ready_id, #{ReadyExecution.hydration_columns}
          FROM solid_queue_ready_executions re
          INNER JOIN solid_queue_jobs jobs ON jobs.id = re.job_id
          #{conditions.gsub("solid_queue_ready_executions", "re")}
          ORDER BY re.priority ASC, re.job_id ASC
          LIMIT #{limit.to_i}
          FOR UPDATE OF re SKIP LOCKED
        SQL

        ReadyExecution.transaction(isolation: :read_committed) do
          result = ReadyExecution.connection.select_all(select_sql)
          next [] if result.rows.empty?

          rows = hydrate_candidates(result, process_id)
          move_to_claimed(rows, process_id)
          rows.map(&:last)
        end
      end

      # A single multi-row insert is a "simple insert", so InnoDB allocates
      # its auto-increment ids consecutively in every autoinc lock mode and
      # LAST_INSERT_ID reports the first id of the batch
      def insert_jobs_returning_ids(job_rows)
        Job.insert_all!(job_rows)
        first = Job.connection.select_value("SELECT LAST_INSERT_ID()").to_i
        (first...(first + job_rows.size)).to_a
      end
    end
  end
end
