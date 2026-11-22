# frozen_string_literal: true

module SolidQueue
  class ClaimedExecution
    # On PostgreSQL, a job that ran successfully is marked finished and its
    # claim deleted in one statement, instead of locking the claim, updating
    # the job and deleting the claim. The claim is deleted first, as it was
    # locked first, and the job is updated only if the claim was still there,
    # so a claim released or pruned meanwhile leaves the job alone, as before.
    #
    # It's for jobs kept once finished and not in a batch, whose update
    # counts them out of it. Callbacks on the job's update don't run for it.
    #
    # It needs Active Record 8 or later.
    module FinishInOneStatement
      private
        def finished
          return super unless SolidQueue.preserve_finished_jobs? && !job.batched? && finishable_on_connection?

          now = Time.current
          finalized = transaction { delete_claim_and_finish_job(now) } > 0

          if finalized
            attributes = [ "finished_at", *Job.timestamp_attributes_for_update_in_model ]
            attributes.each { |attribute| job[attribute] = now }
            job.clear_attribute_changes(attributes)
            job.unblock_next_blocked_job
          end
        end

        def delete_claim_and_finish_job(now)
          self.class.with_connection do |connection|
            jobs = Job.quoted_table_name
            set = [ "finished_at", *Job.timestamp_attributes_for_update_in_model ].map { |attribute| "#{connection.quote_column_name(attribute)} = $2" }
            binds = [
              ActiveRecord::Relation::QueryAttribute.new("id", id, self.class.type_for_attribute(:id)),
              ActiveRecord::Relation::QueryAttribute.new("finished_at", now, Job.type_for_attribute(:finished_at))
            ]

            # As the UPDATE and DELETE it replaces would
            ActiveRecord::Base.clear_query_caches_for_current_thread if connection.pool.dirties_query_cache

            connection.exec_update(<<~SQL.squish, "#{self.class.name} Finish", binds)
              WITH claim AS (DELETE FROM #{self.class.quoted_table_name} WHERE id = $1 RETURNING job_id)
              UPDATE #{jobs} SET #{set.join(", ")} FROM claim WHERE #{jobs}.id = claim.job_id
            SQL
          end
        end

        # A PostgreSQL connection that allows writes. Active Record takes a
        # statement starting with WITH for a read, and wouldn't stop it.
        def finishable_on_connection?
          self.class.with_connection do |connection|
            defined?(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter) && connection.is_a?(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter) &&
              !connection.preventing_writes?
          end
        end
    end
  end
end
