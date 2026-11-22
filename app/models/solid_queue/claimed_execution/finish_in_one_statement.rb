# frozen_string_literal: true

module SolidQueue
  class ClaimedExecution
    # On PostgreSQL, a job that ran successfully is marked finished and its
    # claim deleted in one statement, instead of a transaction that locks the
    # claim, updates the job and deletes the claim. The claim is deleted
    # first, as it was locked first, and the job is updated only if the claim
    # was still there, so a claim released or pruned meanwhile leaves the job
    # alone, as before. A job with a concurrency limit then releases its lock
    # outside the statement, as it did outside the transaction.
    #
    # It's for jobs kept once finished, when nothing would run on the job's
    # update or the claim's destroy: a job in a batch, which its update
    # counts out of the batch, finishes as before, like other jobs.
    #
    # Outside a transaction the statement runs on its own and commits by
    # itself. Inside one, it runs in it.
    #
    # It needs Active Record 8 or later.
    module FinishInOneStatement
      private
        def finished
          return super unless finishable_in_one_statement?

          job.unblock_next_blocked_job if finish_in_one_statement
        end

        def finish_in_one_statement
          now = Time.current
          updated = self.class.with_connection do |connection|
            if connection.open_transactions.zero? && !self.class.statement_runnable_on_its_own?(connection)
              transaction { finish_statement(connection, now) }
            else
              finish_statement(connection, now)
            end
          end

          if updated > 0
            attributes = [ "finished_at", *job.class.timestamp_attributes_for_update_in_model ]
            attributes.each { |attribute| job[attribute] = now }
            job.clear_attribute_changes(attributes)
            true
          end
        end

        def finish_statement(connection, now)
          quote = connection.method(:quote_column_name)
          jobs = Job.quoted_table_name
          set = [ "finished_at", *Job.timestamp_attributes_for_update_in_model ].map { |attribute| "#{quote.(attribute)} = $2" }
          binds = [
            ActiveRecord::Relation::QueryAttribute.new("id", id, self.class.type_for_attribute(:id)),
            ActiveRecord::Relation::QueryAttribute.new("finished_at", now, Job.type_for_attribute(:finished_at))
          ]

          # As the UPDATE and DELETE it replaces would
          ActiveRecord::Base.clear_query_caches_for_current_thread if connection.pool.dirties_query_cache

          self.class.cancelling_if_interrupted(connection, on_its_own: !connection.transaction_open?) do
            connection.exec_update(<<~SQL.squish, "#{self.class.name} Finish", binds)
              WITH claim AS (DELETE FROM #{self.class.quoted_table_name} WHERE id = $1 RETURNING job_id)
              UPDATE #{jobs} SET #{set.join(", ")} FROM claim WHERE #{jobs}.id = claim.job_id
            SQL
          end
        end

        def finishable_in_one_statement?
          SolidQueue.preserve_finished_jobs? &&
            self.class.with_connection { |connection| self.class.statements_writable_on?(connection) } &&
            nothing_runs_on_finish?
        end

        # Whether every callback that would run on the job's update, its
        # validation and the claim's destroy is one that does nothing here.
        def nothing_runs_on_finish?
          job_callbacks = [ *Job._save_callbacks, *Job._update_callbacks, *Job._validate_callbacks, *Job._commit_callbacks, *Job._rollback_callbacks, *Job._before_commit_callbacks.to_a ]
          claim_callbacks = [ *self.class._destroy_callbacks, *self.class._commit_callbacks, *self.class._rollback_callbacks, *self.class._before_commit_callbacks.to_a ]

          job_callbacks.all? { |callback| nothing_runs_for?(job, callback.filter) } && claim_callbacks.all? { |callback| nothing_runs_for?(self, callback.filter) }
        end

        def nothing_runs_for?(record, filter)
          case filter
          when :update_batch_progress then !record.batched?
          when :cant_modify_encrypted_attributes_when_frozen then !record.frozen?
          when /\Aautosave_associated_records_for_(.+)\z/
            association = $1.to_sym
            !record.association_cached?(association) || Array(record.association(association).target).none?(&:changed_for_autosave?)
          else false
          end
        end
    end
  end
end
