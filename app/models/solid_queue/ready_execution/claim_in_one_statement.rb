# frozen_string_literal: true

module SolidQueue
  class ReadyExecution
    # On PostgreSQL, jobs are claimed from a queue in one statement: it locks
    # the next ready executions, as before, inserts their claims, deletes them
    # and returns the claims with their jobs, which are loaded with them. That's
    # instead of selecting them, inserting the claims, loading them back and
    # deleting the ready executions, in a transaction, then loading each job
    # on its own before performing it.
    #
    # It's for connections that allow writes. Others claim as before.
    #
    # It needs Active Record 8 or later.
    module ClaimInOneStatement
      private
        def select_and_lock(queue_relation, process_id, limit)
          return super unless limit > 0 && claimable_in_one_statement?

          claim_statement(queue_relation, process_id, limit).tap do |claimed|
            # As before, only when there was something to claim
            if claimed.any?
              job_ids = claimed.map(&:job_id)
              SolidQueue.instrument(:claim, process_id: process_id, job_ids: job_ids, size: claimed.size, claimed_job_ids: job_ids)
            end
          end
        end

        def claimable_in_one_statement?
          with_connection do |connection|
            defined?(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter) && connection.is_a?(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter) &&
              !connection.preventing_writes?
          end
        end

        def claim_statement(queue_relation, process_id, limit)
          with_connection do |connection|
            # With its values in the text, so there's a prepared statement per queue and limit
            candidates = queue_relation.ordered.limit(limit).non_blocking_lock.select(:id, :job_id).to_sql
            binds = [ ActiveRecord::Relation::QueryAttribute.new("process_id", process_id, ClaimedExecution.type_for_attribute(:process_id)) ]
            claims, jobs = ClaimedExecution.quoted_table_name, Job.quoted_table_name

            # As the statements it replaces would
            ActiveRecord::Base.clear_query_caches_for_current_thread if connection.pool.dirties_query_cache

            # The candidates' text is left as is, since it may quote queue names
            result = connection.select_all("WITH candidates AS (#{candidates}), " + <<~SQL.squish, "#{name} Claim", binds, preparable: true)
              claimed AS (
                INSERT INTO #{claims} (job_id, process_id, created_at)
                SELECT job_id, CAST($1 AS #{ClaimedExecution.columns_hash["process_id"].sql_type}), #{connection.high_precision_current_timestamp} FROM candidates
                RETURNING id, job_id, process_id, created_at
              ), deleted AS (
                DELETE FROM #{quoted_table_name} USING candidates WHERE #{quoted_table_name}.id = candidates.id
              )
              SELECT #{jobs}.*, claimed.id AS claimed_id, claimed.process_id AS claimed_process_id, claimed.created_at AS claimed_created_at
              FROM claimed JOIN #{jobs} ON #{jobs}.id = claimed.job_id
              ORDER BY claimed.id
            SQL

            result.to_a.map do |row|
              claim = ClaimedExecution.instantiate("id" => row.delete("claimed_id"), "job_id" => row["id"],
                "process_id" => row.delete("claimed_process_id"), "created_at" => row.delete("claimed_created_at"))
              claim.association(:job).target = Job.instantiate(row)
              claim
            end
          end
        end
    end
  end
end
