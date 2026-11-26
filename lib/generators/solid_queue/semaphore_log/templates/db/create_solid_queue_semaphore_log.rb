# The table DatabaseAdapters::PostgresqlWithSemaphoreLog keeps semaphores in.
# A semaphore is the newest row of its key, until that row expires. Taking or
# giving back a slot inserts a row, and the dispatcher's concurrency
# maintenance deletes the rows that newer ones replaced or that expired.
class CreateSolidQueueSemaphoreLog < ActiveRecord::Migration[7.1]
  def change
    create_table :solid_queue_semaphore_log do |t|
      t.string :key, null: false
      t.bigint :semaphore_id, null: false # the id of the row that created the semaphore
      t.integer :value, null: false
      t.datetime :expires_at, null: false
      t.datetime :created_at, null: false

      # A key's newest row is the first one read going backwards
      t.index [ :key, :id ]
    end
  end
end
