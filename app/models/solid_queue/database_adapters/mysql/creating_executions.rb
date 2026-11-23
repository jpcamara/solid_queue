# frozen_string_literal: true

module SolidQueue
  module DatabaseAdapters
    class Mysql
      module CreatingExecutions
        # Without the savepoint create_or_find_by! wraps the insert in: MySQL
        # rolls back only the statement that hit the unique index, so the
        # transaction around it carries on.
        def create_execution(execution_class, job)
          execution_class.create!(job: job)
        rescue ActiveRecord::RecordNotUnique
          execution_class.find_by!(job_id: job.id)
        end
      end
    end
  end
end
