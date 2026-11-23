require "test_helper"

class SolidQueue::DatabaseAdaptersTest < ActiveSupport::TestCase
  test "PostgreSQL on Active Record 8 or later gets its own adapter, other databases the base one" do
    expected = if SolidQueue::Record.connection.adapter_name == "PostgreSQL" && ActiveRecord.version >= Gem::Version.new("8.0")
      SolidQueue::DatabaseAdapters::Postgresql
    else
      SolidQueue::DatabaseAdapters::Base
    end

    assert_instance_of expected, SolidQueue::Record.database_adapter
    assert_same SolidQueue::Record.database_adapter, SolidQueue::ReadyExecution.database_adapter
  end
end
