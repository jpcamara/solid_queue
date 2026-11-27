# frozen_string_literal: true

require "rails/generators/active_record"

# Copies the migration that creates the semaphore log, for
# SolidQueue::DatabaseAdapters::PostgresqlWithSemaphoreLog
class SolidQueue::SemaphoreLogGenerator < Rails::Generators::Base
  include ActiveRecord::Generators::Migration

  source_root File.expand_path("templates", __dir__)

  class_option :database, type: :string, aliases: %i[ --db ], default: "queue",
    desc: "The database that Solid Queue uses. Defaults to `queue`"

  def copy_migration
    migration_template "db/create_solid_queue_semaphore_log.rb", File.join(db_migrate_path, "create_solid_queue_semaphore_log.rb"), skip: true
  end
end
