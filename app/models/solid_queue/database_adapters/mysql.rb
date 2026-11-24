# frozen_string_literal: true

module SolidQueue
  module DatabaseAdapters
    # Used on MySQL, with mysql2 or trilogy. Each operation it runs its own
    # way is in a module of its own.
    class Mysql < Base
      include Claiming, Finishing, CreatingExecutions
    end
  end
end
