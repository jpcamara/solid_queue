# frozen_string_literal: true

module SolidQueue
  module DatabaseAdapters
    class Postgresql
      # Semaphores kept in solid_queue_semaphore_log, which only ever has rows
      # inserted, instead of a row per key that every slot taken and given back
      # updates. The functions the solid_queue:semaphore_log generator's
      # migration creates do the work: each takes an advisory lock on the key,
      # held until the transaction ends, reads the key's newest row and inserts
      # the next one.
      #
      # An updated row leaves its old version behind until vacuum removes it,
      # and vacuum can't while any transaction older than it is open, on the
      # primary or, with hot_standby_feedback, on a replica. A busy key's index
      # entries then lead to thousands of dead versions, and every lookup walks
      # them. Here a key's newest row is the first index entry read, however
      # many rows came before it, and old rows go when their partition is
      # truncated, which doesn't wait for vacuum.
      module SemaphoreLog
        def take_slot(job)
          write("SELECT solid_queue_semaphore_wait($1, $2, $3, $4)", "#{Semaphore.name} Wait",
            [ key_bind(job.concurrency_key), limit_bind(job.concurrency_limit), time_bind(job.concurrency_duration.from_now), time_bind(Time.current) ])
        end

        def give_back_slot(job)
          write("SELECT solid_queue_semaphore_signal($1, $2, $3, $4, $5)", "#{Semaphore.name} Signal",
            [ key_bind(job.concurrency_key), id_bind(job.acquired_semaphore_id), limit_bind(job.acquired_concurrency_limit || job.concurrency_limit),
              time_bind(job.concurrency_duration.from_now), time_bind(Time.current) ]).present?
        end

        def keys_with_free_slots(keys)
          return [] if keys.empty?

          Semaphore.with_connection do |connection|
            connection.select_values(<<~SQL.squish, "#{Semaphore.name} Free", [ json_bind(keys), time_bind(Time.current) ])
              SELECT keys.key FROM json_array_elements_text($1::json) AS keys(key)
              LEFT JOIN LATERAL (
                SELECT value, expires_at FROM solid_queue_semaphore_log WHERE key = keys.key ORDER BY id DESC LIMIT 1
              ) newest ON true
              WHERE newest.value IS NULL OR newest.expires_at <= $2 OR newest.value > 0
            SQL
          end
        end

        # Rotates the log instead: a semaphore that has expired is ignored
        # already, and goes with its partition.
        def expire_semaphores(batch_size)
          write("SELECT solid_queue_semaphore_log_rotate($1)", "#{Semaphore.name} Rotate", [ time_bind(Time.current) ])
        end

        private
          # Runs a call to a function that writes. Active Record takes a SELECT
          # for a read, so it wouldn't stop it while writes are prevented.
          def write(sql, name, binds)
            Semaphore.with_connection do |connection|
              raise ActiveRecord::ReadOnlyError, "Write query attempted while in readonly mode: #{sql}" if connection.preventing_writes?

              connection.select_value(sql, name, binds)
            end
          end

          def take_slot_sql(key:, limit:, expires_at:, now:, condition: nil)
            <<~SQL
              SELECT id FROM (SELECT solid_queue_semaphore_wait(#{key}, #{limit}, #{expires_at}, #{now}) AS id #{"WHERE #{condition}" if condition}) taken
              WHERE id IS NOT NULL
            SQL
          end

          def hold_semaphore_sql(semaphore_id:, key:, now:)
            "SELECT #{semaphore_id} AS id WHERE solid_queue_semaphore_held(#{key}, #{semaphore_id}, #{now})"
          end

          def give_back_slot_sql(semaphore_id:, key:, limit:, expires_at:, now:, handed_over:)
            <<~SQL
              SELECT id FROM (SELECT solid_queue_semaphore_signal(#{key}, #{semaphore_id}, #{limit}, #{expires_at}, #{now}, #{handed_over}) AS id) given
              WHERE id IS NOT NULL
            SQL
          end

          def take_slots_for_all(connection, wanted, now)
            connection.exec_query("SELECT * FROM solid_queue_semaphore_wait_all($1::json, $2)", "#{Semaphore.name} Wait All", [ json_bind(wanted), time_bind(now) ])
              .rows.to_h { |key, semaphore_id, taken| [ key, [ semaphore_id, taken ] ] }
          end

          def key_bind(key)
            ActiveRecord::Relation::QueryAttribute.new("key", key, Semaphore.type_for_attribute(:key))
          end

          def limit_bind(limit)
            ActiveRecord::Relation::QueryAttribute.new("limit", limit, Semaphore.type_for_attribute(:value))
          end

          def id_bind(id)
            ActiveRecord::Relation::QueryAttribute.new("semaphore_id", id, Semaphore.type_for_attribute(:id))
          end
      end
    end
  end
end
