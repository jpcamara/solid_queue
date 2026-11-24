# frozen_string_literal: true

module SolidQueue
  module DatabaseAdapters
    class Postgresql
      module Claiming
        # Claims in one statement: it locks the next ready executions, as Base
        # does, inserts their claims, deletes the ready executions and returns
        # the claims with their jobs, which are loaded with them. That's instead
        # of selecting, inserting, loading the claims back and deleting, in a
        # transaction, then loading each job on its own before performing it.
        # It's a statement per queue, as Base has a transaction per queue.
        # Connections that prevent writes claim as in Base.
        def claim(queue_list, process_id, limit)
          ReadyExecution.with_connection do |connection|
            return super if connection.preventing_writes?

            ReadyExecution.claim_from_each_queue(queue_list, limit) do |queue_relation, remaining|
              claim_in_one_statement(connection, queue_relation, process_id, remaining).tap do |claimed|
                # As Base, only when there was something to claim
                if claimed.any?
                  job_ids = claimed.map(&:job_id)
                  SolidQueue.instrument(:claim, process_id: process_id, job_ids: job_ids, size: claimed.size, claimed_job_ids: job_ids)
                end
              end
            end
          end
        end

        private
          def claim_in_one_statement(connection, queue_relation, process_id, limit)
            # With its values in the text, which may quote queue names, so
            # there's a prepared statement per queue and limit
            candidates = queue_relation.ordered.limit(limit).non_blocking_lock.select(:id, :job_id).to_sql

            # As the statements it replaces would
            ActiveRecord::Base.clear_query_caches_for_current_thread if connection.pool.dirties_query_cache

            # Prepared, which Active Record only does for a string when told it can
            result = connection.select_all("WITH candidates AS (#{candidates}), #{claim_sql}", "SolidQueue::ReadyExecution Claim", [ process_id ], preparable: true)

            result.to_a.map do |row|
              claim = ClaimedExecution.instantiate("id" => row.delete("claimed_id"), "job_id" => row["id"],
                "process_id" => row.delete("claimed_process_id"), "created_at" => row.delete("claimed_created_at"))
              claim.association(:job).target = Job.instantiate(row)
              claim
            end
          end

          # Follows the candidates' query. $1 is the process's id.
          def claim_sql
            @claim_sql ||= begin
              ready, claims, jobs = ReadyExecution.quoted_table_name, ClaimedExecution.quoted_table_name, Job.quoted_table_name

              <<~SQL.squish.freeze
                claimed AS (
                  INSERT INTO #{claims} (job_id, process_id, created_at)
                  SELECT job_id, CAST($1 AS bigint), CURRENT_TIMESTAMP FROM candidates
                  RETURNING id, job_id, process_id, created_at
                ), deleted AS (
                  DELETE FROM #{ready} USING candidates WHERE #{ready}.id = candidates.id
                )
                SELECT #{jobs}.*, claimed.id AS claimed_id, claimed.process_id AS claimed_process_id,
                  claimed.created_at AS claimed_created_at
                FROM claimed JOIN #{jobs} ON #{jobs}.id = claimed.job_id
                ORDER BY claimed.id
              SQL
            end
          end
      end
    end
  end
end
