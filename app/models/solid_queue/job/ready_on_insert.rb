# frozen_string_literal: true

module SolidQueue
  class Job
    # The INSERT of a job being created goes through the database adapter,
    # which may dispatch the job, and track it in its batch, in the same
    # statement. It's still Job.create!: only its INSERT is the adapter's, so
    # validations and callbacks run as before, and a job the adapter
    # dispatched isn't dispatched or tracked again after it.
    module ReadyOnInsert
      extend ActiveSupport::Concern

      class_methods do
        # The INSERT of a record being created. Active Record 7.2 and later
        # pass it the connection.
        def _insert_record(*insert)
          job = ActiveSupport::IsolatedExecutionState[:solid_queue_job_being_created]
          return super unless job&.class == self

          database_adapter.insert_job(job, *insert) { super }
        end
      end

      # Set by an adapter that made the job ready, or blocked, with its INSERT
      attr_writer :made_ready_on_insert

      # Whether the save in progress opened its own transaction, rather than
      # joining one already open.
      def saving_in_own_transaction?
        @saving_in_own_transaction
      end

      def with_transaction_returning_status
        # A thread without a connection has no transaction open, except on a
        # pinned connection, whose transaction the adapter also checks for
        @saving_in_own_transaction = new_record? && !self.class.connection_pool.active_connection?&.transaction_open?
        super
      ensure
        @saving_in_own_transaction = false
      end

      def prepare_for_execution
        super unless @made_ready_on_insert
      end

      private
        # Wraps the create callbacks, so the flag set by the insert holds
        # for the after_create callbacks and is cleared once they've run,
        # even if the save fails.
        def _create_record(...)
          state = ActiveSupport::IsolatedExecutionState
          outer, state[:solid_queue_job_being_created] = state[:solid_queue_job_being_created], self
          super
        ensure
          state[:solid_queue_job_being_created] = outer
          @made_ready_on_insert = false
        end

        def create_batch_execution
          super unless @made_ready_on_insert
        end
    end
  end
end
