# frozen_string_literal: true

module SolidQueue
  module DatabaseAdapters
    class Postgresql
      module Enqueuing
        # Inserts a job that's due and without a concurrency limit with its
        # ready execution in one statement, instead of an INSERT for each. A
        # job in a batch is counted into the batch and tracked by the same
        # statement, which inserts nothing when the batch has finished. Others
        # are inserted as in Base.
        #
        # Active Record begins a transaction only when something first runs in
        # it. When the job's save opened its transaction, nothing has run in it
        # yet, and no callback can write after the insert, the statement is the
        # save's only write: it runs on its own and commits by itself, and the
        # transaction, never begun, sends neither BEGIN nor COMMIT. after_commit
        # callbacks still run when the save ends. Otherwise the statement runs
        # inside the transaction, so what callbacks write goes with it.
        def insert_job(job, connection, values, returning)
          return super unless insertable_ready?(job, connection)

          returned = insert_ready(job, connection, values, Array(returning))
          raise Batch::AlreadyFinished, "Can't add jobs into an already finished batch" if returned.nil?

          job.made_ready_on_insert = true
          returned
        end

        private
          def insert_ready(job, connection, values, returning)
            binds = values.map do |name, value|
              value.is_a?(ActiveModel::Attribute) ? value : ActiveRecord::Relation::QueryAttribute.new(name.to_s, value, Job.type_for_attribute(name))
            end
            columns = values.keys.map { |name| connection.quote_column_name(name) }
            ready_columns = ReadyExecution.assumable_attributes_from_job.map { |name| connection.quote_column_name(name) }
            returned = returning.map { |name| "job.#{connection.quote_column_name(name)}" }
            # Only what's read from the job, so the arguments aren't returned
            from_job = [ "id", "created_at", *ReadyExecution.assumable_attributes_from_job, *returning ]

            placeholders = Array.new(binds.size) { |i| "$#{i + 1}" }.join(", ")
            from_job << "batch_id" if job.batched?
            job_returning = from_job.map(&:to_s).uniq.map { |name| connection.quote_column_name(name) }.join(", ")

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
                  INSERT INTO #{Job.quoted_table_name} (#{columns.join(", ")})
                  SELECT #{placeholders} WHERE EXISTS (SELECT 1 FROM batch)
                  RETURNING #{job_returning}
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
                  INSERT INTO #{Job.quoted_table_name} (#{columns.join(", ")})
                  VALUES (#{placeholders})
                  RETURNING #{job_returning}
                ), ready AS (
                  INSERT INTO #{ReadyExecution.quoted_table_name} (job_id, #{ready_columns.join(", ")}, created_at)
                  SELECT id, #{ready_columns.join(", ")}, created_at FROM job
                )
                SELECT #{returned.join(", ")} FROM job
              SQL
            end

            on_its_own = job.saving_in_own_transaction? && connection.open_transactions == 1 &&
              !connection.current_transaction.materialized? && !connection.current_transaction.isolation_level &&
              nothing_written_after_insert?(job) && running_queries_cancellable? && nothing_to_read?(connection)

            # As the INSERT it replaces would
            ActiveRecord::Base.clear_query_caches_for_current_thread if connection.pool.dirties_query_cache

            completed = false
            begin
              connection.internal_exec_query(sql, "#{Job.name} Create", binds, materialize_transactions: !on_its_own).rows.first.tap { completed = true }
            ensure
              # Interrupted, or its thread killed, while it waits on a lock,
              # the statement would still commit once it gets it. Cancel it,
              # as rolling back the transaction would.
              connection.send(:cancel_any_running_query) if on_its_own && !completed
            end
          end

          # A connection that allows writes, since Active Record takes a
          # statement starting with WITH for a read and wouldn't stop it, and
          # that uses INSERT ... RETURNING. Its internal_exec_query is gone on
          # Rails main.
          def insertable_ready?(job, connection)
            !connection.preventing_writes? && connection.use_insert_returning? && connection.respond_to?(:internal_exec_query) &&
              job.due? && !job.concurrency_limited?
          end

          # Whether every callback that runs after the insert, inside the save's
          # transaction (after and around save and create, and before_commit), is
          # one that doesn't write for a job made ready on insert.
          def nothing_written_after_insert?(job)
            callbacks = [ *job.class._save_callbacks, *job.class._create_callbacks ].reject { |callback| callback.kind == :before }
            (callbacks + job.class._before_commit_callbacks.to_a).all? do |callback|
              case callback.filter
              when :prepare_for_execution, :create_batch_execution then true
              when /\Aautosave_associated_records_for_(.+)\z/ then !job.association_cached?($1.to_sym)
              else false
              end
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
    end
  end
end
