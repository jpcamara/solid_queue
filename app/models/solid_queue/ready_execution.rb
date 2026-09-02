# frozen_string_literal: true

module SolidQueue
  class ReadyExecution < Execution
    scope :queued_as, ->(queue_name) { where(queue_name: queue_name) }

    assumes_attributes_from_job

    class << self
      def claim(queue_list, limit, process_id)
        QueueSelector.new(queue_list, self).scoped_relations.flat_map do |queue_relation|
          if single_statement_claim_supported?
            single_statement_claim(queue_relation, process_id, limit).tap do |locked|
              limit -= locked.size
            end
          elsif sqlite_claim_supported?
            sqlite_claim(queue_relation, process_id, limit).tap do |locked|
              limit -= locked.size
            end
          elsif mysql_claim_supported?
            mysql_claim(queue_relation, process_id, limit).tap do |locked|
              limit -= locked.size
            end
          else
            select_and_lock(queue_relation, process_id, limit).tap do |locked|
              limit -= locked.size
              preload_jobs(locked)
            end
          end
        end
      end

      def preload_jobs(claimed)
        return if claimed.empty?

        jobs_by_id = SolidQueue::Job.where(id: claimed.map(&:job_id)).index_by(&:id)
        claimed.each { |execution| execution.association(:job).target = jobs_by_id[execution.job_id] }
      end

      def single_statement_claim_supported?
        connection.adapter_name == "PostgreSQL"
      end

      # Only the columns the execution path reads: converting and instantiating
      # unused columns is measurable client CPU at high claim rates
      def hydration_columns
        @hydration_columns ||= (%w[ id active_job_id queue_name class_name arguments priority concurrency_key batch_id ] &
          SolidQueue::Job.column_names).map { |c| "jobs.#{c}" }.join(", ")
      end

      def sqlite_claim_supported?
        connection.adapter_name == "SQLite"
      end

      def mysql_claim_supported?
        connection.adapter_name.match?(/mysql/i)
      end

      # Same rows and locks as select_and_lock + claiming: candidates locked
      # with SKIP LOCKED (only the ready rows, via FOR UPDATE OF), jobs read in
      # the same query, then two raw statements move them ready -> claimed.
      # A multi-statement client runs the whole transaction in two round trips.
      def mysql_claim(queue_relation, process_id, limit)
        return [] if limit <= 0

        conditions = queue_relation.where_clause.any? ? "WHERE #{queue_relation.where_clause.ast.to_sql}" : ""
        # Same row locks on the rows we take; READ COMMITTED skips the gap
        # locks REPEATABLE READ adds to the ordered range scan, which serialize
        # concurrent claimers against enqueuers on the index head
        select_sql = <<~SQL
          SELECT re.id AS ready_id, #{hydration_columns}
          FROM solid_queue_ready_executions re
          INNER JOIN solid_queue_jobs jobs ON jobs.id = re.job_id
          #{conditions.gsub("solid_queue_ready_executions", "re")}
          ORDER BY re.priority ASC, re.job_id ASC
          LIMIT #{limit.to_i}
          FOR UPDATE OF re SKIP LOCKED
        SQL

        claim_mysql_mutex.synchronize do
          client = claim_mysql_client
          begin
            # Sent as plain statements so any proxy or pooler passes them
            # through. If a pooler splits the isolation hint from the
            # transaction it silently degrades to REPEATABLE READ — still
            # correct, only slower under contention.
            client.query("SET TRANSACTION ISOLATION LEVEL READ COMMITTED")
            client.query("BEGIN")
            result = client.query(select_sql, cache_rows: false)

            if result.nil? || result.count.zero?
              client.query("ROLLBACK")
              next []
            end

            now = Time.current.utc.strftime("'%Y-%m-%d %H:%M:%S.%6N'")
            claimed = result.map do |attrs|
              ready_id = attrs.delete("ready_id")
              job = SolidQueue::Job.instantiate(attrs)
              execution = SolidQueue::ClaimedExecution.instantiate_claimed(job_id: job.id, process_id: process_id)
              execution.association(:job).target = job
              [ ready_id, execution ]
            end

            values = claimed.map { |_, e| "(#{e.job_id}, #{process_id ? process_id.to_i : "NULL"}, #{now})" }.join(",")
            client.query("INSERT INTO solid_queue_claimed_executions (job_id, process_id, created_at) VALUES #{values}")
            client.query("DELETE FROM solid_queue_ready_executions WHERE id IN (#{claimed.map(&:first).join(",")})")
            client.query("COMMIT")

            claimed.map(&:last)
          rescue Exception
            begin client.query("ROLLBACK"); rescue Exception; @claim_mysql_client = nil; end
            raise
          end
        end.tap do |executions|
          job_ids = executions.map(&:job_id)
          SolidQueue.instrument(:claim, process_id: process_id, job_ids: job_ids,
            claimed_job_ids: job_ids, size: executions.size)
        end
      end

      def claim_mysql_mutex
        @claim_mysql_mutex ||= Mutex.new
      end

      # The claimer owns one multi-statement connection for its whole life,
      # holding the same locks and isolation an Active Record one would
      def claim_mysql_client
        @claim_mysql_client ||= begin
          config = connection_pool.db_config.configuration_hash
          Mysql2::Client.new(config)
        end
      end

      # SQLite is single-writer, so candidates need no row locks: read them
      # joined with their jobs in one query, then move them ready -> claimed
      # with two statements in one transaction. Same rows, same atomicity.
      # All three statements are prepared once per connection and shape;
      # id lists bind as JSON arrays so the shapes stay stable.
      def sqlite_claim(queue_relation, process_id, limit)
        return [] if limit <= 0

        candidates_sql = queue_relation.ordered.limit(limit).select(:id, :job_id).to_sql.sub(/LIMIT \d+\z/, "LIMIT ?")
        select_stmt = sqlite_prepared(candidates_sql) do
          <<~SQL
            SELECT c.id AS ready_id, #{hydration_columns}
            FROM (#{candidates_sql}) c INNER JOIN solid_queue_jobs jobs ON jobs.id = c.job_id
          SQL
        end
        columns = select_stmt.columns
        rows = select_stmt.execute(limit.to_i).to_a
        return [] if rows.empty?

        claimed = rows.map do |row|
          attrs = row.is_a?(Hash) ? row : columns.zip(row).to_h
          ready_id = attrs.delete("ready_id")
          job = SolidQueue::Job.instantiate(attrs)
          execution = SolidQueue::ClaimedExecution.instantiate_claimed(job_id: job.id, process_id: process_id)
          execution.association(:job).target = job
          [ ready_id, execution ]
        end

        insert_stmt = sqlite_prepared("claim_insert") do
          "INSERT INTO solid_queue_claimed_executions (job_id, process_id, created_at) SELECT value, ?, ? FROM json_each(?)"
        end
        delete_stmt = sqlite_prepared("claim_delete") do
          "DELETE FROM solid_queue_ready_executions WHERE id IN (SELECT value FROM json_each(?))"
        end
        job_ids_json = "[#{claimed.map { |_, e| e.job_id }.join(",")}]"
        now = connection.quoted_date(Time.current)

        SolidQueue::SqliteWriterFunnel.acquire(connection_pool) do
          transaction do
            insert_stmt.execute(process_id, now, job_ids_json).to_a
            delete_stmt.execute("[#{claimed.map(&:first).join(",")}]").to_a
          end
        end

        claimed.map(&:last).tap do |executions|
          job_ids = executions.map(&:job_id)
          SolidQueue.instrument(:claim, process_id: process_id, job_ids: job_ids,
            claimed_job_ids: job_ids, size: executions.size)
        end
      end

      # Statements prepared once per connection and shape, on the same
      # connection the claim's transaction runs on
      def sqlite_prepared(key)
        conn = connection
        prepared = conn.instance_variable_get(:@sq_prepared_claims) || conn.instance_variable_set(:@sq_prepared_claims, {})
        prepared[key] ||= conn.raw_connection.prepare(yield)
      end


      # A plain statement every poll: session-level PREPARE breaks through
      # transaction-pooling proxies, and re-parsing the CTE costs a few
      # percent that portability is worth
      def execute_prepared_claim(sql, shape_key)
        connection.select_all(sql)
      end

      # The same rows, locks and atomicity as select_and_lock + claiming, in
      # one statement: candidates are locked with SKIP LOCKED, moved into
      # claimed executions and deleted from ready, with the job row hydrated
      # alongside so execution doesn't need to load it
      def single_statement_claim(queue_relation, process_id, limit)
        return [] if limit <= 0

        candidates_sql = queue_relation.ordered.limit(limit).non_blocking_lock.select(:id, :job_id).to_sql

        @claim_sql_cache ||= {}
        sql = <<~SQL
          WITH candidates AS (#{candidates_sql}),
          deleted AS (
            DELETE FROM solid_queue_ready_executions WHERE id IN (SELECT id FROM candidates)
          ),
          claimed AS (
            INSERT INTO solid_queue_claimed_executions (job_id, process_id, created_at)
            SELECT job_id, #{process_id ? connection.quote(process_id) : "NULL"}, now() FROM candidates
            RETURNING id, job_id, process_id, created_at
          )
          SELECT claimed.id AS claimed_id, claimed.job_id AS claimed_job_id,
                 claimed.process_id AS claimed_process_id, claimed.created_at AS claimed_created_at,
                 #{hydration_columns}
          FROM claimed INNER JOIN solid_queue_jobs jobs ON jobs.id = claimed.job_id
        SQL

        result = execute_prepared_claim(sql, candidates_sql)
        job_columns = SolidQueue::Job.column_names
        result.rows.map do |row|
          attrs = result.columns.zip(row).to_h
          execution = SolidQueue::ClaimedExecution.instantiate(
            "id" => attrs["claimed_id"], "job_id" => attrs["claimed_job_id"],
            "process_id" => attrs["claimed_process_id"], "created_at" => attrs["claimed_created_at"]
          )
          job = SolidQueue::Job.instantiate(attrs.slice(*job_columns))
          execution.association(:job).target = job
          execution
        end.tap do |claimed|
          job_ids = claimed.map(&:job_id)
          SolidQueue.instrument(:claim, process_id: process_id, job_ids: job_ids,
            claimed_job_ids: job_ids, size: claimed.size)
        end
      end

      def aggregated_count_across(queue_list)
        QueueSelector.new(queue_list, self).scoped_relations.map(&:count).sum
      end

      private
        def select_and_lock(queue_relation, process_id, limit)
          return [] if limit <= 0

          transaction do
            candidates = select_candidates(queue_relation, limit)
            lock_candidates(candidates, process_id)
          end
        end

        def select_candidates(queue_relation, limit)
          # Force query execution here with #to_a to avoid unintended FOR UPDATE query executions
          queue_relation.ordered.limit(limit).non_blocking_lock.select(:id, :job_id).to_a
        end

        def lock_candidates(executions, process_id)
          return [] if executions.none?

          SolidQueue::ClaimedExecution.claiming(executions.map(&:job_id), process_id) do |claimed|
            ids_to_delete = executions.index_by(&:job_id).values_at(*claimed.map(&:job_id)).map(&:id)
            where(id: ids_to_delete).delete_all
          end
        end


        def discard_jobs(job_ids)
          Job.release_all_concurrency_locks Job.where(id: job_ids)
          super
        end
    end
  end
end
