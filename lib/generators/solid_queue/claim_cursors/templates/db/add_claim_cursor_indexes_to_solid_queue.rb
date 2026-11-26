# The indexes SolidQueue.claim_cursors seeks in on PostgreSQL: a seek past a
# queue's (priority, id) position, with every queue or one, and a floored
# pass's window of a queue by id. Built concurrently, so claims carry on.
class AddClaimCursorIndexesToSolidQueue < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    add_index :solid_queue_ready_executions, [ :priority, :id ], name: "index_solid_queue_poll_all_by_id", algorithm: :concurrently, if_not_exists: true
    add_index :solid_queue_ready_executions, [ :queue_name, :priority, :id ], name: "index_solid_queue_poll_by_queue_and_id", algorithm: :concurrently, if_not_exists: true
    add_index :solid_queue_ready_executions, [ :queue_name, :id ], name: "index_solid_queue_poll_by_queue_floored", algorithm: :concurrently, if_not_exists: true
  end
end
