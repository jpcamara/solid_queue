# frozen_string_literal: true

module SolidQueue
  module DatabaseAdapters
    class Postgresql
      module Finishing
        # Finishes in one statement, on its own without BEGIN and COMMIT, which
        # deletes the claim and marks the job finished, instead of locking the
        # claim, updating the job and deleting the claim, in a transaction. The
        # claim is deleted first, as it was locked first, and the job is
        # updated only if the claim was still there, so a claim released or
        # pruned meanwhile leaves the job alone, as in Base.
        #
        # It's for jobs kept once finished and not in a batch, whose update
        # counts them out of it, with nothing else to save, finished outside a
        # transaction, as workers finish them. Callbacks on the job's update
        # don't run for it. Others finish as in Base.
        def finish(claimed_execution)
          job = claimed_execution.job
          return super unless SolidQueue.preserve_finished_jobs? && !job.batched? && !job.has_changes_to_save?

          now = Time.current
          updated = ClaimedExecution.with_connection do |connection|
            return super unless finishable_on_connection?(connection)

            with_statement_autocommit(connection, eligible: true) do |autocommit|
              if autocommit
                delete_claim_and_finish_job(connection, claimed_execution, now)
              else
                ClaimedExecution.transaction { delete_claim_and_finish_job(connection, claimed_execution, now) }
              end
            end
          end
          finalized = updated > 0

          if finalized
            attributes = [ "finished_at", *("updated_at" if Job.record_timestamps) ]
            attributes.each { |attribute| job[attribute] = now }
            job.clear_attribute_changes(attributes)
          end

          finalized
        end

        private
          def delete_claim_and_finish_job(connection, claimed_execution, now)
            # As the UPDATE and DELETE it replaces would
            ActiveRecord::Base.clear_query_caches_for_current_thread if connection.pool.dirties_query_cache

            # Prepared, which Active Record only does for a string when told it can
            connection.select_all(finish_sql(Job.record_timestamps),
              "SolidQueue::ClaimedExecution Finish", [ claimed_execution.id, now ], preparable: true).length
          end

          # $1 is the claim's id and $2 the time the job finished, which is
          # also when it was updated, unless the job doesn't record timestamps.
          def finish_sql(with_timestamps)
            (@finish_sql ||= {})[with_timestamps] ||= begin
              claims, jobs = ClaimedExecution.quoted_table_name, Job.quoted_table_name
              set = with_timestamps ? "finished_at = $2, updated_at = $2" : "finished_at = $2"

              <<~SQL.squish.freeze
                WITH claim AS (DELETE FROM #{claims} WHERE id = $1 RETURNING job_id)
                UPDATE #{jobs} SET #{set}
                FROM claim WHERE #{jobs}.id = claim.job_id
                RETURNING #{jobs}.id
              SQL
            end
          end

          # A connection that allows writes, with no transaction open, whose
          # rollback would leave the job in memory finished. Active Record takes
          # a statement starting with WITH for a read, and wouldn't stop it.
          def finishable_on_connection?(connection)
            !connection.preventing_writes? && !connection.transaction_open?
          end
      end
    end
  end
end
