# frozen_string_literal: true

require "rails/generators/active_record"

# Copies the migration that adds the indexes claim cursors seek in, for
# SolidQueue.claim_cursors on PostgreSQL
class SolidQueue::ClaimCursorsGenerator < Rails::Generators::Base
  include ActiveRecord::Generators::Migration

  source_root File.expand_path("templates", __dir__)

  class_option :database, type: :string, aliases: %i[ --db ], default: "queue",
    desc: "The database that Solid Queue uses. Defaults to `queue`"

  def copy_migration
    migration_template "db/add_claim_cursor_indexes_to_solid_queue.rb", File.join(db_migrate_path, "add_claim_cursor_indexes_to_solid_queue.rb"), skip: true
  end
end
