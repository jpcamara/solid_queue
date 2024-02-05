class CreateSolidQueueBatchTable < ActiveRecord::Migration[7.1]
  def change
    create_table :solid_queue_job_batches do |t|
      t.references :job, index: { unique: true }
      t.string :job_class
      t.string :completion_type
      t.datetime :finished_at
      t.datetime :changed_at
      t.datetime :last_changed_at
      t.timestamps

      t.index [ :finished_at ]
      t.index [ :changed_at ]
      t.index [ :last_changed_at ]
    end

    add_reference :solid_queue_jobs, :batch, index: true
    add_foreign_key :solid_queue_jobs, :solid_queue_job_batches, column: :batch_id, on_delete: :cascade
    add_foreign_key :solid_queue_job_batches, :solid_queue_jobs, column: :job_id
  end
end