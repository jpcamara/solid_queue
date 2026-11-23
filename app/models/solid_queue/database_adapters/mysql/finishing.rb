# frozen_string_literal: true

module SolidQueue
  module DatabaseAdapters
    class Mysql
      module Finishing
        # Deletes the claim without reading it first.
        def finish(claimed_execution)
          claimed_execution.finalize_claim_by_deleting { claimed_execution.job.finished! }
        end
      end
    end
  end
end
