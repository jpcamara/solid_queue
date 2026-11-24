# frozen_string_literal: true

module SolidQueue
  module DatabaseAdapters
    class Mysql
      module Claiming
        # Loads the claims with their jobs, in one query, instead of loading
        # each job on its own before performing it.
        def claim(queue_relation, process_id, limit)
          ReadyExecution.claim_in_transaction(queue_relation, process_id, limit, with_jobs: true)
        end
      end
    end
  end
end
