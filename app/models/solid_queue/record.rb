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

      # Runs a statement on its own, without BEGIN and COMMIT, when it's
      # eligible and that's safe: the connection can cancel a running query
      # and the server hasn't closed it. Otherwise the block is told to use a
      # transaction. Interrupted while it waits on a lock, a statement on its
      # own would still commit once it gets the lock, so it's cancelled.
      def with_statement_autocommit(connection, eligible:)
        autocommit = eligible && running_queries_cancellable? && nothing_to_read?(connection)
        completed = false
        yield(autocommit).tap { completed = true }
      ensure
        connection.send(:cancel_any_running_query) if autocommit && !completed
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
        # A connection the server has closed (restarted, failed over, or
        # terminated the backend) has its closing message waiting to be read.
        # BEGIN would find that out and reconnect, but the statement on its
        # own can't be retried safely, so it goes in a transaction instead.
        def nothing_to_read?(connection)
          raw = connection.send(:any_raw_connection)
          # wait_readable, unlike IO.select, doesn't start a thread under a fiber scheduler
          !raw.socket_io.wait_readable(0)
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

ActiveSupport.run_load_hooks :solid_queue_record, SolidQueue::Record
