# frozen_string_literal: true

module SolidQueue
  module DatabaseAdapters
    class Postgresql
      module Clearing
        # Clears finished jobs and batches in batches that each start at the
        # finished_at where the last one ended, instead of at the start of the
        # index. The rows deleted by earlier batches leave their index entries
        # behind until vacuum removes them, which it can't while an older
        # transaction is open, and each batch from the start would read through
        # them all again. The first batch still reads through what earlier runs
        # left.
        #
        # A batch starts at the last one's latest finished_at, not after it, so
        # rows that finished at that same time and didn't fit in it come next.
        # Connections that prevent writes clear as in Base.
        def clear_finished(batch_size:, finished_before:, class_name:, sleep_between_batches:, &)
          clear_by_finished_at(Job.clearable(finished_before: finished_before, class_name: class_name), batch_size, sleep_between_batches, &)
        end

        def clear_finished_batches(batch_size:, finished_before:, sleep_between_batches:, &)
          clear_by_finished_at(Batch.clearable(finished_before: finished_before), batch_size, sleep_between_batches, &)
        end

        private
          def clear_by_finished_at(clearable, batch_size, sleep_between_batches)
            return yield if clearable.model.with_connection(&:preventing_writes?)

            from = nil
            loop do
              finished_ats = clear_batch(clearable, batch_size, from)
              sleep(sleep_between_batches) if sleep_between_batches > 0
              break if finished_ats.empty?

              from = finished_ats.max
            end
          end

          # Deletes the next batch and returns the finished_at of each row deleted
          def clear_batch(clearable, batch_size, from)
            model = clearable.model
            batch = clearable.order(:finished_at).limit(batch_size)
            batch = batch.where(finished_at: from..) if from

            model.with_connection do |connection|
              # As the DELETE it replaces would
              ActiveRecord::Base.clear_query_caches_for_current_thread if connection.pool.dirties_query_cache

              connection.exec_query("DELETE FROM #{model.quoted_table_name} WHERE id IN (#{batch.select(:id).to_sql}) RETURNING finished_at", "#{model.name} Clear")
                .cast_values.map { |finished_at| model.type_for_attribute(:finished_at).cast(finished_at) }
            end
          end
      end
    end
  end
end
