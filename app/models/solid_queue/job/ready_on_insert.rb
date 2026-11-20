# frozen_string_literal: true

module SolidQueue
  class Job
    # On PostgreSQL, a job that's due and without a concurrency limit is
    # inserted with its ready execution in one statement, instead of an INSERT
    # for each. A job in a batch is counted into the batch and tracked by the
    # same statement, which inserts nothing when the batch has finished. It's
    # still Job.create!: only its INSERT is replaced, so validations and
    # callbacks run as before, and the job isn't made ready or tracked again
    # after it.
    #
    # Active Record begins a transaction only when something first runs in it.
    # When the job's save opened its transaction, nothing has run in it yet, and
    # no callback can write after the insert, the statement is the save's only
    # write: it runs on its own and commits by itself, and the transaction,
    # never begun, sends neither BEGIN nor COMMIT. after_commit callbacks still
    # run when the save ends. Otherwise the statement runs inside the
    # transaction, so what callbacks write goes with it.
    #
    # It needs Active Record 8 or later.
    module ReadyOnInsert
      extend ActiveSupport::Concern

      class_methods do
        # The INSERT of a record being created
        def _insert_record(connection, values, returning)
          job = ActiveSupport::IsolatedExecutionState[:solid_queue_job_being_created]
          return super unless job&.class == self && job.ready_on_insert?(connection)

          returned = insert_ready(job, connection, values, Array(returning))
          raise Batch::AlreadyFinished, "Can't add jobs into an already finished batch" if returned.nil?

          job.made_ready_on_insert = true
          returned
        end

        private
          def insert_ready(job, connection, values, returning)
            binds = values.map do |name, value|
              value.is_a?(ActiveModel::Attribute) ? value : ActiveRecord::Relation::QueryAttribute.new(name.to_s, value, type_for_attribute(name))
            end
            columns = values.keys.map { |name| connection.quote_column_name(name) }
            ready_columns = ReadyExecution.assumable_attributes_from_job.map { |name| connection.quote_column_name(name) }
            returned = returning.map { |name| "job.#{connection.quote_column_name(name)}" }

            placeholders = Array.new(binds.size) { |i| "$#{i + 1}" }.join(", ")

            sql = if job.batched?
              binds += [
                ActiveRecord::Relation::QueryAttribute.new("total_jobs", BatchExecution.count_new_jobs_among([ job ]), Batch.type_for_attribute(:total_jobs)),
                ActiveRecord::Relation::QueryAttribute.new("id", job.batch_id, Batch.type_for_attribute(:id))
              ]

              # Counted first, as BatchExecution.create_all_from_jobs does, and
              # the job is inserted only if the batch was still unfinished.
              <<~SQL.squish
                WITH batch AS (
                  UPDATE #{Batch.quoted_table_name} SET total_jobs = total_jobs + $#{binds.size - 1}
                  WHERE id = $#{binds.size} AND finished_at IS NULL
                  RETURNING id
                ), job AS (
                  INSERT INTO #{quoted_table_name} (#{columns.join(", ")})
                  SELECT #{placeholders} WHERE EXISTS (SELECT 1 FROM batch)
                  RETURNING *
                ), ready AS (
                  INSERT INTO #{ReadyExecution.quoted_table_name} (job_id, #{ready_columns.join(", ")}, created_at)
                  SELECT id, #{ready_columns.join(", ")}, created_at FROM job
                ), batch_execution AS (
                  INSERT INTO #{BatchExecution.quoted_table_name} (job_id, batch_id, created_at)
                  SELECT id, batch_id, created_at FROM job
                )
                SELECT #{returned.join(", ")} FROM job
              SQL
            else
              <<~SQL.squish
                WITH job AS (
                  INSERT INTO #{quoted_table_name} (#{columns.join(", ")})
                  VALUES (#{placeholders})
                  RETURNING *
                ), ready AS (
                  INSERT INTO #{ReadyExecution.quoted_table_name} (job_id, #{ready_columns.join(", ")}, created_at)
                  SELECT id, #{ready_columns.join(", ")}, created_at FROM job
                )
                SELECT #{returned.join(", ")} FROM job
              SQL
            end

            on_its_own = job.saving_in_own_transaction? && connection.open_transactions == 1 &&
              !connection.current_transaction.materialized? && job.nothing_written_after_insert?

            connection.internal_exec_query(sql, "#{name} Create", binds, materialize_transactions: !on_its_own).rows.first.tap do
              connection.clear_query_cache
            end
          end
      end

      attr_writer :made_ready_on_insert

      def ready_on_insert?(connection)
        postgresql?(connection) && due? && !concurrency_limited?
      end

      # Whether the save in progress opened its own transaction, rather than
      # joining one already open.
      def saving_in_own_transaction?
        @saving_in_own_transaction
      end

      # Whether every callback that runs after the insert, inside the save's
      # transaction (after and around save and create, and before_commit), is
      # one that doesn't write for a job made ready on insert.
      def nothing_written_after_insert?
        callbacks = [ *self.class._save_callbacks, *self.class._create_callbacks ].reject { |callback| callback.kind == :before }
        (callbacks + self.class._before_commit_callbacks.to_a).all? do |callback|
          case callback.filter
          when :prepare_for_execution, :create_batch_execution then true
          when /\Aautosave_associated_records_for_(.+)\z/ then !association_cached?($1.to_sym)
          else false
          end
        end
      end

      def with_transaction_returning_status
        @saving_in_own_transaction = new_record? && !self.class.connection_pool.with_connection(&:transaction_open?)
        super
      ensure
        @saving_in_own_transaction = false
      end

      def prepare_for_execution
        super unless @made_ready_on_insert
      end

      private
        # Wraps the create callbacks, so the flag set by the insert holds
        # for the after_create callbacks and is cleared once they've run.
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

        def postgresql?(connection)
          defined?(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter) && connection.is_a?(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter)
        end
    end
  end
end
