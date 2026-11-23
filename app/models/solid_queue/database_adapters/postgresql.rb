# frozen_string_literal: true

module SolidQueue
  module DatabaseAdapters
    # Used on PostgreSQL with Active Record 8 or later.
    class Postgresql < Base
      # Finishes in one statement, which deletes the claim and marks the job
      # finished, instead of locking the claim, updating the job and deleting
      # the claim. The claim is deleted first, as it was locked first, and the
      # job is updated only if the claim was still there, so a claim released
      # or pruned meanwhile leaves the job alone, as in Base.
      #
      # It's for jobs kept once finished and not in a batch, whose update
      # counts them out of it, with nothing else to save, finished outside a
      # transaction, as workers finish them. Callbacks on the job's update
      # don't run for it. Others finish as in Base.
      def finish(claimed_execution)
        job = claimed_execution.job
        return super unless SolidQueue.preserve_finished_jobs? && !job.batched? && !job.has_changes_to_save? && finishable_on_connection?

        now = Time.current
        finalized = ClaimedExecution.transaction { delete_claim_and_finish_job(claimed_execution, now) } > 0

        if finalized
          attributes = finished_attributes
          attributes.each { |attribute| job[attribute] = now }
          job.clear_attribute_changes(attributes)
        end

        finalized
      end

      private
        def delete_claim_and_finish_job(claimed_execution, now)
          ClaimedExecution.with_connection do |connection|
            claims, jobs = ClaimedExecution.quoted_table_name, Job.quoted_table_name
            set = finished_attributes.map { |attribute| "#{connection.quote_column_name(attribute)} = $2" }
            binds = [
              ActiveRecord::Relation::QueryAttribute.new("id", claimed_execution.id, ClaimedExecution.type_for_attribute(:id)),
              ActiveRecord::Relation::QueryAttribute.new("finished_at", now, Job.type_for_attribute(:finished_at))
            ]

            # As the UPDATE and DELETE it replaces would
            ActiveRecord::Base.clear_query_caches_for_current_thread if connection.pool.dirties_query_cache

            # Prepared, which Active Record only does for a string when told it can
            connection.select_all(<<~SQL.squish, "#{ClaimedExecution.name} Finish", binds, preparable: true).length
              WITH claim AS (DELETE FROM #{claims} WHERE id = $1 RETURNING job_id)
              UPDATE #{jobs} SET #{set.join(", ")} FROM claim WHERE #{jobs}.id = claim.job_id
              RETURNING #{jobs}.id
            SQL
          end
        end

        def finished_attributes
          [ "finished_at", *(Job.timestamp_attributes_for_update_in_model if Job.record_timestamps) ]
        end

        # A connection that allows writes, with no transaction open, whose
        # rollback would leave the job in memory finished. Active Record takes
        # a statement starting with WITH for a read, and wouldn't stop it.
        def finishable_on_connection?
          ClaimedExecution.with_connection do |connection|
            !connection.preventing_writes? && !connection.transaction_open?
          end
        end
    end
  end
end
