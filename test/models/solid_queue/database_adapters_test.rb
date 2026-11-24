require "test_helper"

class SolidQueue::DatabaseAdaptersTest < ActiveSupport::TestCase
  test "PostgreSQL on Active Record 8 or later and MySQL get their own adapters, other databases the base one" do
    connection = SolidQueue::Record.connection

    expected = if connection.adapter_name == "PostgreSQL" && ActiveRecord.version >= Gem::Version.new("8.0")
      SolidQueue::DatabaseAdapters::Postgresql
    elsif connection.adapter_name.in?(%w[ Mysql2 Trilogy ]) && !connection.mariadb?
      SolidQueue::DatabaseAdapters::Mysql
    else
      SolidQueue::DatabaseAdapters::Base
    end

    assert_instance_of expected, SolidQueue::Record.database_adapter
    assert_same SolidQueue::Record.database_adapter, SolidQueue::ReadyExecution.database_adapter
  end
end
