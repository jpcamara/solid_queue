# frozen_string_literal: true

module SolidQueue
  module DatabaseAdapters
    class Postgresql
      module Enqueuing
        # Inserts a job that's due with its ready execution in one statement,
        # instead of an INSERT for each. A job in a batch is counted into the
        # batch and tracked by the same statement, which inserts nothing when
        # the batch has finished. A job with a concurrency limit takes its slot
        # in it too, and is inserted blocked if there's none. One that caps its
        # blocked jobs is inserted blocked only while fewer than max_blocked
        # are, and isn't inserted otherwise, as if discarded after its insert.
        # Others are inserted as in Base.
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
          counted = job.concurrency_max_blocked ? returned.pop : returned
          raise Batch::AlreadyFinished, "Can't add jobs into an already finished batch" unless counted
          raise Job::ReadyOnInsert::Discarded if returned.first.nil?

          if job.concurrency_limited?
            semaphore_id = returned.pop
            job.arguments[Job::ConcurrencyControls::CONCURRENCY_LOCK_KEY] = { "semaphore_id" => semaphore_id, "limit" => job.concurrency_limit } if semaphore_id
          end

          job.made_ready_on_insert = true
          returned
        end

        private
          def insert_ready(job, connection, values, returning)
            binds = values.map do |name, value|
              value.is_a?(ActiveModel::Attribute) ? value : ActiveRecord::Relation::QueryAttribute.new(name.to_s, value, Job.type_for_attribute(name))
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
            ctes, inserted_if, insertable_if, ready_if = [], nil, nil, nil

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

              key = bind.(job.concurrency_key, Semaphore, :key)
              ctes << "semaphore AS (#{take_slot_sql(key:, limit:, expires_at:, now:, condition: inserted_if)})"
              ready_if = "WHERE EXISTS (SELECT 1 FROM semaphore)"

              # As block does. The key is locked before the statement starts, so
              # it counts what the last enqueue on the key committed.
              if job.concurrency_max_blocked
                max_blocked = bind.(job.concurrency_max_blocked, Semaphore, :value)
                insertable_if = "(EXISTS (SELECT 1 FROM semaphore) OR (#{max_blocked} > 0 AND NOT EXISTS (
                  SELECT 1 FROM #{BlockedExecution.quoted_table_name} WHERE concurrency_key = #{key} OFFSET GREATEST(#{max_blocked} - 1, 0) LIMIT 1
                )))"
              end

              arguments = values.keys.index { |name| name.to_s == "arguments" }
              # Added last, as record_concurrency_lock adds it
              lock = "',#{connection.quote_string(Job::ConcurrencyControls::CONCURRENCY_LOCK_KEY.to_json)}:{\"semaphore_id\":' || (SELECT id FROM semaphore) || ',\"limit\":' || #{limit} || '}}'"
              inserted[arguments] = "COALESCE(left(#{inserted[arguments]}, -1) || #{lock}, #{inserted[arguments]})"
              returned << "(SELECT id FROM semaphore)"
            end

            ctes << <<~SQL
              job AS (
                INSERT INTO #{Job.quoted_table_name} (#{columns.join(", ")})
                #{(conditions = [ inserted_if, insertable_if ].compact).any? ? "SELECT #{inserted.join(", ")} WHERE #{conditions.join(" AND ")}" : "VALUES (#{inserted.join(", ")})"}
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

            # A capped job's statement returns a row whether or not the job was
            # inserted, ending with whether it was counted into its batch.
            sql = if job.concurrency_max_blocked
              "WITH #{ctes.join(", ")} SELECT #{returned.join(", ")}, #{job.batched? ? "EXISTS (SELECT 1 FROM batch)" : "true"} FROM (SELECT) one LEFT JOIN job ON true".squish
            else
              "WITH #{ctes.join(", ")} SELECT #{returned.join(", ")} FROM job".squish
            end

            # As the INSERT it replaces would
            ActiveRecord::Base.clear_query_caches_for_current_thread if connection.pool.dirties_query_cache

            with_slots_locked(connection, job.concurrency_limited? ? [ job.concurrency_key ] : [], batches_of: [ job ]) do
              lock_semaphore_first(connection, job) if job.concurrency_max_blocked
              # Not when locking the key ran a statement in the transaction first
              eligible = job.saving_in_own_transaction? && connection.open_transactions == 1 &&
                !connection.current_transaction.materialized? && !connection.current_transaction.isolation_level &&
                nothing_written_after_insert?(job)

              with_statement_autocommit(connection, eligible: eligible) do |autocommit|
                connection.internal_exec_query(sql, "#{Job.name} Create", binds, materialize_transactions: !autocommit).rows.first
              end
            end
          end

          # A connection that allows writes, since Active Record takes a
          # statement starting with WITH for a read and wouldn't stop it, and
          # that uses INSERT ... RETURNING. Its internal_exec_query is gone on
          # Rails main.
          #
          # Not a job with a concurrency limit that discards it on conflict, nor
          # one that caps its blocked jobs with a limit below 1, as its key may
          # be locked by creating its semaphore with every slot free, and it has
          # none. Nor one whose class doesn't load, which skips its limits, nor
          # one whose arguments the statement can't add its slot to.
          def insertable_ready?(job, connection)
            !connection.preventing_writes? && connection.use_insert_returning? && connection.respond_to?(:internal_exec_query) &&
              job.due? &&
              (!job.concurrency_limited? || (job.job_class.present? && !job.concurrency_on_conflict.discard? &&
                (!job.concurrency_max_blocked || job.concurrency_limit >= 1) && slot_recordable_in_arguments?(job)))
          end

          # The statement adds the slot's entry ahead of the serialized arguments'
          # first key, so they need one, and mustn't have the entry already.
          def slot_recordable_in_arguments?(job)
            job.arguments.is_a?(Hash) && job.arguments.any? && !job.arguments.key?(Job::ConcurrencyControls::CONCURRENCY_LOCK_KEY)
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
      end
    end
  end
end
