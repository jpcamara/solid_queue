# frozen_string_literal: true

module SolidQueue
  class Job
    # On PostgreSQL, a job that's due, without a concurrency limit and not in a
    # batch is inserted with its ready execution in one statement, instead of
    # an INSERT for each. It's still Job.create!: only its INSERT is replaced,
    # so validations and callbacks run as before, and the job isn't made ready
    # again after it.
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

          insert_ready(job, connection, values, Array(returning)).tap { job.made_ready_on_insert = true }
        end

        private
          def insert_ready(job, connection, values, returning)
            binds = values.map do |name, value|
              value.is_a?(ActiveModel::Attribute) ? value : ActiveRecord::Relation::QueryAttribute.new(name.to_s, value, type_for_attribute(name))
            end
            columns = values.keys.map { |name| connection.quote_column_name(name) }
            ready_columns = ReadyExecution.assumable_attributes_from_job.map { |name| connection.quote_column_name(name) }
            returned = returning.map { |name| "job.#{connection.quote_column_name(name)}" }
            # Only what's read from the job, so the arguments aren't returned
            from_job = [ "id", "created_at", *ReadyExecution.assumable_attributes_from_job, *returning ]

            sql = <<~SQL.squish
              WITH job AS (
                INSERT INTO #{quoted_table_name} (#{columns.join(", ")})
                VALUES (#{Array.new(binds.size) { |i| "$#{i + 1}" }.join(", ")})
                RETURNING #{from_job.map(&:to_s).uniq.map { |name| connection.quote_column_name(name) }.join(", ")}
              ), ready AS (
                INSERT INTO #{ReadyExecution.quoted_table_name} (job_id, #{ready_columns.join(", ")}, created_at)
                SELECT id, #{ready_columns.join(", ")}, created_at FROM job
              )
              SELECT #{returned.join(", ")} FROM job
            SQL

            on_its_own = job.saving_in_own_transaction? && connection.open_transactions == 1 &&
              !connection.current_transaction.materialized? && !connection.current_transaction.isolation_level &&
              job.nothing_written_after_insert? && running_queries_cancellable? && nothing_to_read?(connection)

            # As the INSERT it replaces would
            ActiveRecord::Base.clear_query_caches_for_current_thread if connection.pool.dirties_query_cache

            completed = false
            begin
              connection.internal_exec_query(sql, "#{name} Create", binds, materialize_transactions: !on_its_own).rows.first.tap { completed = true }
            ensure
              # Interrupted, or its thread killed, while it waits on a lock,
              # the statement would still commit once it gets it. Cancel it,
              # as rolling back the transaction would.
              connection.send(:cancel_any_running_query) if on_its_own && !completed
            end
          end

          # A connection the server has closed (restarted, failed over, or
          # terminated the backend) has its closing message waiting to be read.
          # BEGIN would find that out and reconnect, but the statement on its
          # own can't be retried safely, so it goes in a transaction instead.
          def nothing_to_read?(connection)
            raw = connection.send(:any_raw_connection)
            !IO.select([ raw.socket_io ], nil, nil, 0)
          rescue PG::Error, IOError
            false
          end

          # Active Record can't cancel a running query with libpq 18 and pg
          # before 1.6, so the statement isn't run on its own there.
          def running_queries_cancellable?
            !(PG.library_version >= 18_00_00 && Gem::Version.new(PG::VERSION) < Gem::Version.new("1.6.0"))
          end
      end

      attr_writer :made_ready_on_insert

      def ready_on_insert?(connection)
        insertable_ready_on?(connection) && due? && !concurrency_limited? && !batched?
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

        # A PostgreSQL connection that allows writes, since Active Record
        # takes a statement starting with WITH for a read and wouldn't stop
        # it, and that uses INSERT ... RETURNING. Its internal_exec_query is
        # gone on Rails main.
        def insertable_ready_on?(connection)
          defined?(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter) && connection.is_a?(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter) &&
            !connection.preventing_writes? && connection.use_insert_returning? && connection.respond_to?(:internal_exec_query)
        end
    end
  end
end
