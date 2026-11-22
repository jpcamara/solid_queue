# frozen_string_literal: true

module SolidQueue
  class Job
    # On PostgreSQL, a job that's due is inserted with its ready execution in
    # one statement, instead of an INSERT for each. A job in a batch is counted
    # into the batch and tracked by the same statement, which inserts nothing
    # when the batch has finished. A job with a concurrency limit takes its
    # slot in it too, and is inserted blocked if there's none. It's still
    # Job.create!: only its INSERT is replaced, so validations and callbacks
    # run as before, and the job isn't dispatched or tracked again after it.
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

          if job.concurrency_limited?
            semaphore_id = returned.pop
            job.arguments[ConcurrencyControls::CONCURRENCY_LOCK_KEY] = { "semaphore_id" => semaphore_id, "limit" => job.concurrency_limit } if semaphore_id
          end

          job.made_ready_on_insert = true
          returned
        end

        private
          def insert_ready(job, connection, values, returning)
            binds = values.map do |name, value|
              value.is_a?(ActiveModel::Attribute) ? value : ActiveRecord::Relation::QueryAttribute.new(name.to_s, value, type_for_attribute(name))
            end
            bind = ->(value, model, attribute) do
              binds << ActiveRecord::Relation::QueryAttribute.new(attribute.to_s, value, model.type_for_attribute(attribute))
              "CAST($#{binds.size} AS #{model.columns_hash[attribute.to_s].sql_type})"
            end
            quote = connection.method(:quote_column_name)

            columns = values.keys.map(&quote)
            inserted = Array.new(binds.size) { |i| "$#{i + 1}" }
            ready_columns = ReadyExecution.assumable_attributes_from_job.map(&quote).join(", ")
            returned = returning.map { |name| "job.#{quote.(name)}" }
            # Only what's read from the job, so the arguments aren't returned
            from_job = [ "id", "created_at", *ReadyExecution.assumable_attributes_from_job, *returning ]
            from_job << "batch_id" if job.batched?
            from_job << "concurrency_key" if job.concurrency_limited?
            ctes, inserted_if, ready_if = [], nil, nil

            # Counted first, as BatchExecution.create_all_from_jobs does, and
            # nothing else is written unless the batch was still unfinished.
            if job.batched?
              ctes << <<~SQL
                batch AS (
                  UPDATE #{Batch.quoted_table_name} SET total_jobs = total_jobs + #{bind.(BatchExecution.count_new_jobs_among([ job ]), Batch, :total_jobs)}
                  WHERE id = #{bind.(job.batch_id, Batch, :id)} AND finished_at IS NULL
                  RETURNING id
                )
              SQL
              inserted_if = "EXISTS (SELECT 1 FROM batch)"
            end

            # The job takes a slot as Semaphore.wait does: it creates the
            # semaphore with the rest of its limit, or takes one from the
            # semaphore there if any is left. It's made ready if it got one and
            # blocked if not, and the slot it got is recorded in its arguments.
            if job.concurrency_limited?
              expires_at, limit = bind.(job.concurrency_duration.from_now, Semaphore, :expires_at), bind.(job.concurrency_limit, Semaphore, :value)
              now = bind.(Time.current, Semaphore, :created_at)

              ctes << <<~SQL
                semaphore AS (
                  INSERT INTO #{Semaphore.quoted_table_name} (key, value, expires_at, created_at, updated_at)
                  SELECT #{bind.(job.concurrency_key, Semaphore, :key)}, #{limit} - 1, #{expires_at}, #{now}, #{now}
                  #{"WHERE #{inserted_if}" if inserted_if}
                  ON CONFLICT (key) DO UPDATE SET value = #{Semaphore.quoted_table_name}.value - 1, expires_at = EXCLUDED.expires_at
                  WHERE #{Semaphore.quoted_table_name}.value > 0
                  RETURNING id
                )
              SQL
              ready_if = "WHERE EXISTS (SELECT 1 FROM semaphore)"

              arguments = values.keys.index { |name| name.to_s == "arguments" }
              # Added last, as record_concurrency_lock adds it
              lock = "',#{connection.quote_string(ConcurrencyControls::CONCURRENCY_LOCK_KEY.to_json)}:{\"semaphore_id\":' || (SELECT id FROM semaphore) || ',\"limit\":' || #{limit} || '}}'"
              inserted[arguments] = "COALESCE(left(#{inserted[arguments]}, -1) || #{lock}, #{inserted[arguments]})"
              returned << "(SELECT id FROM semaphore)"
            end

            ctes << <<~SQL
              job AS (
                INSERT INTO #{quoted_table_name} (#{columns.join(", ")})
                #{inserted_if ? "SELECT #{inserted.join(", ")} WHERE #{inserted_if}" : "VALUES (#{inserted.join(", ")})"}
                RETURNING #{from_job.map(&:to_s).uniq.map(&quote).join(", ")}
              )
            SQL
            ctes << <<~SQL
              ready AS (
                INSERT INTO #{ReadyExecution.quoted_table_name} (job_id, #{ready_columns}, created_at)
                SELECT id, #{ready_columns}, created_at FROM job #{ready_if}
              )
            SQL
            if job.concurrency_limited?
              ctes << <<~SQL
                blocked AS (
                  INSERT INTO #{BlockedExecution.quoted_table_name} (job_id, queue_name, priority, concurrency_key, expires_at, created_at)
                  SELECT id, queue_name, priority, concurrency_key, #{expires_at}, created_at FROM job WHERE NOT EXISTS (SELECT 1 FROM semaphore)
                )
              SQL
            end
            if job.batched?
              ctes << <<~SQL
                batch_execution AS (
                  INSERT INTO #{BatchExecution.quoted_table_name} (job_id, batch_id, created_at)
                  SELECT id, batch_id, created_at FROM job
                )
              SQL
            end

            sql = "WITH #{ctes.join(", ")} SELECT #{returned.join(", ")} FROM job".squish

            on_its_own = job.saving_in_own_transaction? && connection.open_transactions == 1 &&
              !connection.current_transaction.materialized? && !connection.current_transaction.isolation_level &&
              job.nothing_written_after_insert? && statement_runnable_on_its_own?(connection)

            # As the INSERT it replaces would
            ActiveRecord::Base.clear_query_caches_for_current_thread if connection.pool.dirties_query_cache

            cancelling_if_interrupted(connection, on_its_own:) do
              connection.internal_exec_query(sql, "#{name} Create", binds, materialize_transactions: !on_its_own).rows.first
            end
          end
      end

      attr_writer :made_ready_on_insert

      # Not a job with a concurrency limit that discards it on conflict, nor
      # one whose class doesn't load, which skips its limits, nor one whose
      # arguments the statement can't add its slot to.
      def ready_on_insert?(connection)
        insertable_ready_on?(connection) && due? &&
          (!concurrency_limited? || (job_class.present? && !concurrency_on_conflict.discard? && slot_recordable_in_arguments?))
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
        # A thread without a connection has no transaction open, except on a
        # pinned connection, whose transaction insert_ready also checks for
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

        # A PostgreSQL connection that allows writes and uses INSERT ...
        # RETURNING. Its internal_exec_query is gone on Rails main.
        def insertable_ready_on?(connection)
          self.class.statements_writable_on?(connection) && connection.use_insert_returning? && connection.respond_to?(:internal_exec_query)
        end

        # The statement adds the slot's entry ahead of the serialized arguments'
        # first key, so they need one, and mustn't have the entry already.
        def slot_recordable_in_arguments?
          arguments.is_a?(Hash) && arguments.any? && !arguments.key?(ConcurrencyControls::CONCURRENCY_LOCK_KEY)
        end
    end
  end
end
