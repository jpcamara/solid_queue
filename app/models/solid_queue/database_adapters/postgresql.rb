# frozen_string_literal: true

module SolidQueue
  module DatabaseAdapters
    # Used on PostgreSQL with Active Record 8 or later. Each operation it runs
    # its own way is in a module of its own.
    class Postgresql < Base
      include Enqueuing, Claiming, Finishing
    end
  end
end
