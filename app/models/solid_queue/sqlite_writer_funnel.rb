# frozen_string_literal: true

module SolidQueue
  # SQLite allows one writer at a time: funneling this process's write
  # transactions through one mutex turns the database's busy-wait backoff
  # into free in-process queueing. A no-op yield on other adapters.
  module SqliteWriterFunnel
    MUTEX = Mutex.new

    def self.acquire(connection_pool)
      if connection_pool.db_config.adapter.include?("sqlite")
        MUTEX.synchronize { yield }
      else
        yield
      end
    end
  end
end
