# frozen_string_literal: true

module SolidQueue
  class DatabaseAdapter
    # Databases without a specific adapter run the regular Active Record
    # paths everywhere
    class Generic < DatabaseAdapter
      def fast_paths?
        false
      end
    end
  end
end
