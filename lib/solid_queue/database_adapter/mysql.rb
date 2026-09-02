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

      # Four exchanges, the minimum for two atomic inserts without a
      # multi-statement packet: BEGIN, the jobs insert, the ready insert,
      # COMMIT. The jobs insert is a "simple insert", so InnoDB allocates
      # its auto-increment ids consecutively in every autoinc lock mode,
      # and the OK packet the insert already returns carries the first id,
      # which Active Record hands back from `insert` — no LAST_INSERT_ID
      # round trip. Each insert is one lean Arel statement rather than the
      # bulk API's per-call builder.
      def write_enqueue_batch(job_rows, now)
        Job.transaction do
          count_batched(job_rows)
          first = Job.connection.insert(insert_manager(Job, job_rows.map { |row| job_values(row, now) }), "SolidQueue::Job Create", "id")
          ids = (first...(first + job_rows.size)).to_a
          Job.connection.insert(insert_manager(ReadyExecution, job_rows.each_with_index.map { |row, i|
            { job_id: ids[i], queue_name: row[:queue_name], priority: row[:priority], created_at: now }
          }), "SolidQueue::ReadyExecution Create", "id")
          track_batched(job_rows, ids, now)
          ids
        end
      end

      private
        def job_values(row, now)
          values = {
            queue_name: row[:queue_name], class_name: row[:class_name],
            arguments: Job.type_for_attribute("arguments").serialize(row[:arguments]), priority: row[:priority],
            active_job_id: row[:active_job_id], scheduled_at: row[:scheduled_at], created_at: now, updated_at: now
          }
          values[:batch_id] = row[:batch_id] if row.key?(:batch_id)
          values
        end

        def insert_manager(model, rows)
          table = model.arel_table
          columns = rows.first.keys
          Arel::InsertManager.new(table).tap do |manager|
            manager.into(table)
            columns.each { |column| manager.columns << table[column] }
            manager.values = manager.create_values_list(rows.map { |row| row.values_at(*columns) })
          end
        end
    end
  end
end
