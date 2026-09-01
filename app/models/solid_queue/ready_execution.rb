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


      # PREPARE the claim once per connection and shape: the CTE is large and
      # re-parsing and re-planning it every poll costs more than running it
      def execute_prepared_claim(sql, shape_key)
        conn = connection
        prepared = conn.instance_variable_get(:@sq_prepared_claims) || conn.instance_variable_set(:@sq_prepared_claims, {})
        name = prepared[shape_key]

        unless name
          name = "sq_claim_#{prepared.size}"
          conn.execute("PREPARE #{name} AS #{sql}")
          prepared[shape_key] = name
        end

        conn.select_all("EXECUTE #{name}")
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
                 jobs.*
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
          SolidQueue.instrument(:claim, process_id: process_id, job_ids: claimed.map(&:job_id),
            claimed_job_ids: claimed.map(&:job_id), size: claimed.size)
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
