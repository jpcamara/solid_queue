# frozen_string_literal: true

module SolidQueue
  module DatabaseAdapters
    class Postgresql
      # The parts of the statements in Enqueuing, BulkEnqueuing, Releasing and
      # Unblocking that take and give back concurrency slots, on a row per key
      # in the semaphores table. An adapter that keeps semaphores elsewhere
      # overrides them. Arguments are SQL: binds, or expressions.
      module Semaphores
        private
          # Runs the block, which takes or gives back slots of the keys' semaphores
          # in its statement. The rows that statement locks are all it needs, and
          # it locks the batches of the jobs given first, as it takes a slot only
          # once the job is counted into its batch.
          def with_slots_locked(connection, keys, batches_of: [])
            yield
          end

          # Locks the job's semaphore, after its batch, in statements of their
          # own, for a statement that counts the jobs blocked on its key: starting
          # after the lock, it counts what the last holder committed. A semaphore
          # that doesn't exist yet is created with every slot free, so there's a
          # row to lock.
          def lock_semaphore_first(connection, job)
            lock_batches(connection, [ job ])
            create_semaphores(connection, [ { key: job.concurrency_key, value: job.concurrency_limit, expires_at: connection.quoted_date(job.concurrency_duration.from_now) } ], Time.current)
          end

          # A query that takes a slot of the key's semaphore, as Semaphore.wait
          # does, when condition holds. It returns the semaphore's id if it got
          # one, and no row if not.
          def take_slot_sql(key:, limit:, expires_at:, now:, condition: nil)
            <<~SQL
              INSERT INTO #{Semaphore.quoted_table_name} (key, value, expires_at, created_at, updated_at)
              SELECT #{key}, #{limit} - 1, #{expires_at}, #{now}, #{now}
              #{"WHERE #{condition}" if condition}
              ON CONFLICT (key) DO UPDATE SET value = #{Semaphore.quoted_table_name}.value - 1, expires_at = EXCLUDED.expires_at
              WHERE #{Semaphore.quoted_table_name}.value > 0
              RETURNING id
            SQL
          end

          # A query that locks the job's semaphore, returning a row if it's still
          # the one of its key and isn't below zero.
          def hold_semaphore_sql(semaphore_id:, key:, now:)
            "SELECT id FROM #{Semaphore.quoted_table_name} WHERE id = #{semaphore_id} AND key = #{key} AND value >= 0 FOR UPDATE"
          end

          # A query that gives the job's slot back to its semaphore, or, when
          # handed_over holds, keeps it taken for the job it's handed to, and
          # returns the semaphore's id. No row if the semaphore is gone or full.
          def give_back_slot_sql(semaphore_id:, key:, limit:, expires_at:, now:, handed_over:)
            <<~SQL
              UPDATE #{Semaphore.quoted_table_name} SET value = value + CASE WHEN #{handed_over} THEN 0 ELSE 1 END, expires_at = #{expires_at}
              WHERE id = #{semaphore_id} AND value < #{limit}
              RETURNING id
            SQL
          end

          # Takes up to n slots for each key in wanted (key, n, limit and
          # expires_at, by key in order), creating the semaphores that don't
          # exist yet. Returns the semaphore's id and how many it gave, by key.
          def take_slots_for_all(connection, wanted, now)
            created = create_semaphores(connection, wanted.map { |w| { key: w[:key], value: w[:limit] - [ w[:n], w[:limit] ].min, expires_at: w[:expires_at] } }, now)
            existing = wanted.reject { |w| created.key?(w[:key]) }
            from_existing = existing.any? ? take_from_semaphores(connection, existing.map { |w| w.slice(:key, :n, :expires_at) }) : {}

            wanted.each_with_object({}) do |w, taken|
              taken[w[:key]] = created.key?(w[:key]) ? [ created[w[:key]], [ w[:n], w[:limit] ].min ] : from_existing.fetch(w[:key], [ nil, 0 ])
            end
          end

          # Inserts the semaphores that don't exist yet, and locks the ones that
          # do: the update's condition is never met, but the row is still locked.
          # Returns the ids of those inserted, by key.
          def create_semaphores(connection, rows, now)
            connection.exec_query(<<~SQL.squish, "#{Semaphore.name} Create All", [ json_bind(rows), time_bind(now) ]).rows.to_h { |id, key| [ key, id ] }
              INSERT INTO #{Semaphore.quoted_table_name} (key, value, expires_at, created_at, updated_at)
              SELECT key, value, expires_at, $2, $2 FROM json_to_recordset($1::json) AS wanted(key text, value integer, expires_at timestamp)
              ON CONFLICT (key) DO UPDATE SET value = #{Semaphore.quoted_table_name}.value WHERE false
              RETURNING id, key
            SQL
          end

          # Takes up to n slots from each existing, and now locked, semaphore.
          # Returns its id and how many it gave, by key.
          def take_from_semaphores(connection, rows)
            connection.exec_query(<<~SQL.squish, "#{Semaphore.name} Take All", [ json_bind(rows) ]).rows.to_h { |id, key, count| [ key, [ id, count ] ] }
              WITH wanted AS (
                SELECT * FROM json_to_recordset($1::json) AS wanted(key text, n integer, expires_at timestamp)
              ), taken AS (
                SELECT semaphores.id, semaphores.key, LEAST(wanted.n, GREATEST(semaphores.value, 0)) AS count, wanted.expires_at
                FROM #{Semaphore.quoted_table_name} semaphores JOIN wanted ON wanted.key = semaphores.key
              ), updated AS (
                UPDATE #{Semaphore.quoted_table_name} SET value = #{Semaphore.quoted_table_name}.value - taken.count, expires_at = taken.expires_at
                FROM taken WHERE #{Semaphore.quoted_table_name}.id = taken.id AND taken.count > 0
              )
              SELECT id, key, count FROM taken
            SQL
          end
      end
    end
  end
end
