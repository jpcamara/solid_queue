# frozen_string_literal: true

module SolidQueue
  # The SQL behind enqueuing, claiming, finishing and releasing jobs, by
  # database. Base runs the models' code that works on every database; a
  # database's adapter overrides an operation it can do in fewer statements,
  # and falls back to Base when it can't. An app or a gem can set its own
  # adapter as SolidQueue.database_adapter.
  module DatabaseAdapters
    class << self
      def for(connection)
        if SolidQueue.database_adapter
          SolidQueue.database_adapter
        elsif postgresql?(connection)
          @postgresql ||= Postgresql.new
        else
          @base ||= Base.new
        end
      end

      private
        def postgresql?(connection)
          defined?(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter) &&
            connection.is_a?(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter) &&
            ActiveRecord.version >= Gem::Version.new("8.0")
        end
    end
  end
end
