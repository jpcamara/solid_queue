# frozen_string_literal: true

module SolidQueue
  module DatabaseAdapters
    # The PostgreSQL adapter, with semaphores kept in an insert-only log (see
    # Postgresql::SemaphoreLog). Opt in by running the solid_queue:semaphore_log
    # generator's migration and setting
    #
    #   SolidQueue.database_adapter = SolidQueue::DatabaseAdapters::PostgresqlWithSemaphoreLog.new
    class PostgresqlWithSemaphoreLog < Postgresql
      include Postgresql::SemaphoreLog
    end
  end
end
