# frozen_string_literal: true

module SolidQueue
  class Record < ActiveRecord::Base
    self.abstract_class = true
    self.strict_loading_by_default = false

    include DistinctValues

    connects_to(**SolidQueue.connects_to) if SolidQueue.connects_to

    class << self
      def non_blocking_lock
        if SolidQueue.use_skip_locked
          lock(Arel.sql("FOR UPDATE SKIP LOCKED"))
        else
          lock
        end
      end

      def supports_insert_conflict_target?
        connection_pool.with_connection do |connection|
          connection.supports_insert_conflict_target?
        end
      end

      # A PostgreSQL connection that allows writes. Active Record takes a
      # statement starting with WITH for a read, and wouldn't stop it.
      def statements_writable_on?(connection)
        defined?(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter) && connection.is_a?(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter) &&
          !connection.preventing_writes?
      end

      # Whether a statement can run on the connection outside a transaction,
      # committing by itself. A connection the server has closed (restarted,
      # failed over, or terminated the backend) has its closing message
      # waiting to be read. BEGIN would find that out and reconnect, but a
      # statement on its own can't be retried safely, so it goes in a
      # transaction instead. And Active Record can't cancel a running query
      # with libpq 18 and pg before 1.6.
      def statement_runnable_on_its_own?(connection)
        running_queries_cancellable? && nothing_to_read?(connection)
      end

      # Interrupted, or its thread killed, while it waits on a lock, a
      # statement on its own would still commit once it gets it. It's
      # cancelled, as rolling back the transaction would.
      def cancelling_if_interrupted(connection, on_its_own:)
        completed = false
        yield.tap { completed = true }
      ensure
        connection.send(:cancel_any_running_query) if on_its_own && !completed
      end

      def warn_about_pending_migrations
        SolidQueue.deprecator.warn(<<~DEPRECATION)
          Solid Queue has pending database migrations. To get the new migration files, run:
            rails solid_queue:update
          And then:
            rails db:migrate
          These migrations will be required after version #{SolidQueue.next_major_version}.0
        DEPRECATION
      end

      # Pass index hints to the query optimizer using SQL comment hints.
      # Uses MySQL 8 optimizer hint query comments, which SQLite and
      # PostgreSQL ignore.
      def use_index(*indexes)
        optimizer_hints "INDEX(#{quoted_table_name} #{indexes.join(', ')})"
      end

      private
        def nothing_to_read?(connection)
          raw = connection.send(:any_raw_connection)
          !IO.select([ raw.socket_io ], nil, nil, 0)
        rescue PG::Error, IOError
          false
        end

        def running_queries_cancellable?
          !(PG.library_version >= 18_00_00 && Gem::Version.new(PG::VERSION) < Gem::Version.new("1.6.0"))
        end
    end
  end
end

ActiveSupport.run_load_hooks :solid_queue_record, SolidQueue::Record
