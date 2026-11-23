# frozen_string_literal: true

module SolidQueue
  # The SQL behind claiming and finishing jobs, by database. Base runs the
  # models' code that works on every database; a database's adapter overrides
  # an operation it can do in fewer statements, and falls back to Base when it
  # can't.
  module DatabaseAdapters
    class << self
      def for(connection)
        if postgresql?(connection)
          @postgresql ||= Postgresql.new
        elsif mysql?(connection)
          @mysql ||= Mysql.new
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

        def mysql?(connection)
          defined?(ActiveRecord::ConnectionAdapters::AbstractMysqlAdapter) &&
            connection.is_a?(ActiveRecord::ConnectionAdapters::AbstractMysqlAdapter) && !connection.mariadb?
        end
    end
  end
end
