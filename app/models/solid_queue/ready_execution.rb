# frozen_string_literal: true

module SolidQueue
  class ReadyExecution < Execution
    scope :queued_as, ->(queue_name) { where(queue_name: queue_name) }

    # Within a priority, claims follow the order rows became ready (id) rather
    # than enqueue order (job_id), matching the claim cursor's index position.
    scope :ordered, -> { order(priority: :asc, id: :asc) }

    assumes_attributes_from_job

    class << self
      def claim(queue_list, limit, process_id)
        QueueSelector.new(queue_list, self).relations_by_queue.flat_map do |key, queue_relation|
          select_and_lock(key, queue_relation, process_id, limit).tap do |locked|
            limit -= locked.size
          end
        end
      end

      def aggregated_count_across(queue_list)
        QueueSelector.new(queue_list, self).scoped_relations.map(&:count).sum
      end

      # Cursors, floors and discovery deadlines are positions in one table's id
      # space, so a process polling several databases keeps a registry per
      # datastore. The pool is the datastore's identity: config names can
      # collide (every raw hash or URL config resolves to "primary"), pools
      # cannot.
      def claim_cursors
        claim_cursors_registry.compute_if_absent(connection_pool) { ClaimCursors.new }
      end

      private
        def claim_cursors_registry
          @claim_cursors_registry ||= Concurrent::Map.new
        end

        def select_and_lock(key, queue_relation, process_id, limit)
          return [] if limit <= 0

          unless claim_cursors_enabled?
            return claim_classically(queue_relation, process_id, limit)
          end

          discovery, floor, position = claim_cursors.state(key)

          case discovery
          when :full    then claim_discovering(key, queue_relation, process_id, limit)
          when :floored then claim_discovering_above(key, floor, position, queue_relation, process_id, limit)
          else
            position ? claim_along_cursor(key, position, queue_relation, process_id, limit) : []
          end
        end

        def claim_classically(queue_relation, process_id, limit)
          _candidates, claimed = claim_candidates(queue_relation, process_id, limit)
          claimed
        end

        # Cursor-free claim in full (priority, id) order. The one pass that reaches
        # rows a floored pass cannot see, so the one that may move the cursor
        # anywhere. Its floor is read before the claim's snapshot, so every row
        # allocated after it is above it.
        def claim_discovering(key, queue_relation, process_id, limit)
          floor = id_watermark
          candidates, claimed = claim_candidates(queue_relation, process_id, limit)

          claim_cursors.record_full_discovery(key, position_of(candidates.last), floor)

          claimed
        end

        # Discovery bounded below by the last full pass's watermark, which every
        # row allocated since then exceeds. A strictly-higher-priority arrival is
        # still found, without rescanning the graveyard buried underneath it.
        def claim_discovering_above(key, floor, position, queue_relation, process_id, limit)
          floored_relation = queue_relation.where("id > ?", floor)

          if position
            claim_below_cursor(key, floored_relation, position, queue_relation, process_id, limit)
          else
            claim_seeding_cursor(key, floored_relation, process_id, limit)
          end
        end

        # The cursor owns everything above itself and the fast path claims it in
        # the same poll: disjoint regions keep claims in (priority, id) order, and
        # leave the cursor to advance only over a range nothing was hidden from.
        def claim_below_cursor(key, floored_relation, position, queue_relation, process_id, limit)
          _candidates, claimed = claim_candidates_without_sorts(
            floored_relation.where("(priority, id) <= (?, ?)", *position), process_id, limit
          )

          claim_cursors.record_floored_discovery(key)

          return claimed if claimed.size >= limit

          claimed + claim_along_cursor(key, position, queue_relation, process_id, limit - claimed.size)
        end

        # With no cursor to bound it, a floored pass spans every priority, and the
        # prefix it claims is a position nothing live was hidden below.
        def claim_seeding_cursor(key, floored_relation, process_id, limit)
          candidates, claimed = claim_candidates_without_sorts(floored_relation, process_id, limit)

          claim_cursors.record_floored_discovery(key, position_of(candidates.last))

          claimed
        end

        # One lexicographic index seek across every priority in the queue key.
        def claim_along_cursor(key, position, queue_relation, process_id, limit)
          candidates, claimed = claim_candidates(
            queue_relation.where("(priority, id) > (?, ?)", *position), process_id, limit
          )

          if candidates.any?
            claim_cursors.advance(key, position_of(candidates.last))
          else
            # Under SKIP LOCKED, empty can also mean every remaining row was
            # locked elsewhere; either way the next discovery re-checks
            claim_cursors.clear(key, position)
          end

          claimed
        end

        def claim_candidates(relation, process_id, limit)
          candidates = nil

          claimed = transaction do
            candidates = select_candidates(relation, limit)
            Array(lock_candidates(candidates, process_id))
          end

          [ candidates, claimed ]
        end

        # Over an all-dead table every plan estimates near zero cost, and the tie
        # can land on a legacy job_id polling index plus a sort that re-reads the
        # whole graveyard a floored query exists to skip. Sorts add nothing the
        # polling indexes don't already provide, so claim with them off -- inside
        # a savepoint, restored before it releases and reverted by PostgreSQL if
        # it rolls back, so the settings can never escape a caller's transaction.
        def claim_candidates_without_sorts(relation, process_id, limit)
          transaction(requires_new: true) do
            sort_settings = connection.select_rows(
              "SELECT name, setting FROM pg_settings WHERE name IN ('enable_sort', 'enable_incremental_sort')"
            )
            sort_settings.each { |name, _| connection.execute("SET LOCAL #{name} = OFF") }

            claim_candidates(relation, process_id, limit).tap do
              sort_settings.each { |name, setting| connection.execute("SET LOCAL #{name} = #{connection.quote(setting)}") }
            end
          end
        end

        # Every id the sequence hands out from now on exceeds this, at every
        # priority, so a pass that reads it before its own snapshot bounds the
        # passes that follow. That stops holding if the sequence caches blocks of
        # ids per backend, and the catalog exposing the cache setting arrived in
        # PostgreSQL 10 -- caching, a missing sequence, and an old server all
        # degrade the same way: no floor, every pass unbounded.
        def id_watermark
          return unless connection.database_version >= 10_00_00
          return unless id_sequence_cache == 1

          connection.select_value("SELECT CASE WHEN is_called THEN last_value END FROM #{connection.quote_table_name(sequence_name)}")
        end

        def id_sequence_cache
          connection.select_value(
            sanitize_sql_array([ "SELECT seqcache FROM pg_sequence WHERE seqrelid = to_regclass(?)", sequence_name ])
          )
        end

        # Row-constructor index seeks and the motivating dead-tuple pathology
        # are PostgreSQL-specific.
        def claim_cursors_enabled?
          SolidQueue.claim_cursors && connection_db_config.adapter.match?(/postg/i)
        end

        def select_candidates(relation, limit)
          # Force query execution here with #to_a to avoid unintended FOR UPDATE query executions
          relation.ordered.limit(limit).non_blocking_lock.select(:id, :job_id, :priority).to_a
        end

        def lock_candidates(executions, process_id)
          return [] if executions.none?

          SolidQueue::ClaimedExecution.claiming(executions.map(&:job_id), process_id) do |claimed|
            ids_to_delete = executions.index_by(&:job_id).values_at(*claimed.map(&:job_id)).map(&:id)
            where(id: ids_to_delete).delete_all
          end
        end

        def position_of(execution)
          [ execution.priority, execution.id ] if execution
        end

        def discard_jobs(job_ids)
          Job.release_all_concurrency_locks Job.where(id: job_ids)
          super
        end
    end
  end
end
