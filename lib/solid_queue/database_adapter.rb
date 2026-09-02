# frozen_string_literal: true

module SolidQueue
  # Database-specific behavior for the hot paths, resolved once from the
  # connection configuration. An adapter knows how its database claims ready
  # jobs, flushes completions, reports ids for bulk inserts, and whether its
  # writes need serializing. Databases without a specific adapter get
  # Generic, which declines the fast paths so everything runs the regular
  # Active Record code.
  class DatabaseAdapter
    class << self
      def resolve
        @resolve ||= case Record.connection_pool.db_config.adapter
        when "postgresql" then Postgresql.new
        when /mysql|trilogy/ then Mysql.new
        when /sqlite/ then Sqlite.new
        else Generic.new
        end
      end
    end

    # Whether the claim, completion and enqueue fast paths apply
    def fast_paths?
      true
    end

    # Whether completions flush from a dedicated thread (single-writer
    # databases) instead of inline on the completing threads
    def dedicated_flusher?
      false
    end

    # Wraps write transactions that must not run concurrently within the
    # process; a no-op except on single-writer databases
    def serialize_writes
      yield
    end

    # Moves up to +limit+ ready executions matching +queue_relation+ into
    # claimed executions and returns them hydrated. Returns nil to send the
    # caller down the regular path.
    def claim(queue_relation, process_id, limit)
      nil
    end

    # Deletes the claimed executions and finishes their jobs in one
    # transaction, dropping their batch tracking rows too when any job is
    # batched: a flush group is either fully durable or not there at all
    def flush_completions(job_ids, tracked: false)
      ClaimedExecution.transaction do
        ClaimedExecution.where(job_id: job_ids).delete_all
        BatchExecution.where(job_id: job_ids).delete_all if tracked
        Job.where(id: job_ids).update_all(finished_at: Time.current)
      end
    end

    # Writes a batch of jobs and their ready executions in one transaction,
    # returning the new job ids in row order. Rows that belong to a job
    # batch join it in the same transaction.
    def write_enqueue_batch(job_rows, now)
      Job.transaction do
        count_batched(job_rows)
        ids = insert_jobs_returning_ids(job_rows)
        ReadyExecution.insert_all!(job_rows.each_with_index.map { |row, i|
          { job_id: ids[i], queue_name: row[:queue_name], priority: row[:priority], created_at: now }
        })
        track_batched(job_rows, ids, now)
        ids
      end
    end

    # Bulk-inserts job rows and returns their new ids in row order. A single
    # multi-row insert draws its ids in row order, so ascending ids are the
    # rows' order whatever order RETURNING reports them in.
    def insert_jobs_returning_ids(job_rows)
      Job.insert_all!(job_rows, returning: [ :id ]).rows.map(&:first).sort
    end

    private
      # Batched rows join their batches the way the regular path does: the
      # batch's total is raised first, which also refuses a finished batch
      # (and takes the batch row's lock before the tracking rows' foreign
      # keys do), then each job gets a tracking row in the same transaction.
      # Retries keep their active_job_id and were counted when they first
      # joined, so they don't count again.
      def count_batched(job_rows)
        job_rows.group_by { |row| row[:batch_id] }.each do |batch_id, rows|
          next if batch_id.nil?

          new_jobs = rows.reject { |row| row[:arguments]["executions"].to_i > 0 }.map { |row| row[:active_job_id] }.uniq.size
          updated = Batch.where(id: batch_id).unfinished.update_all([ "total_jobs = total_jobs + ?", new_jobs ])
          raise Batch::AlreadyFinished, "Can't add jobs into an already finished batch" unless updated > 0
        end
      end

      def track_batched(job_rows, ids, now)
        tracking = job_rows.each_index.filter_map do |i|
          { job_id: ids[i], batch_id: job_rows[i][:batch_id], created_at: now } if job_rows[i][:batch_id]
        end
        BatchExecution.insert_all!(tracking) if tracking.any?
      end

      # A typed bind parameter for a model column: the attribute type
      # serializes the value exactly as the model would
      def bind(model, column, value)
        ActiveRecord::Relation::QueryAttribute.new(column.to_s, value, model.type_for_attribute(column.to_s))
      end

      # Shared two-phase claim: a hydrating read of the candidates, then the
      # ready -> claimed move by id inside the caller-supplied transaction
      # discipline. Subclasses provide the locked (or lock-free) read.
      def hydrate_candidates(result, process_id)
        result.rows.map do |row|
          attrs = result.columns.zip(row).to_h
          ready_id = attrs.delete("ready_id")
          job = Job.instantiate(attrs)
          execution = ClaimedExecution.instantiate_claimed(job_id: job.id, process_id: process_id)
          execution.association(:job).target = job
          [ ready_id, execution ]
        end
      end

      def move_to_claimed(rows, process_id)
        now = Time.current
        ClaimedExecution.insert_all!(rows.map { |_, execution|
          { job_id: execution.job_id, process_id: process_id, created_at: now }
        })
        ReadyExecution.where(id: rows.map(&:first)).delete_all
      end
  end
end
