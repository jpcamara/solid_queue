class CreateSolidQueueWorkflows < ActiveRecord::Migration[7.1]
  def change
    create_table :solid_queue_workflows do |t|
      # t.bigint :batch_id, index: true
      t.string :batch_id, index: true
      t.timestamps
    end

    create_table :solid_queue_workflow_nodes do |t|
      t.references :workflow, null: false, foreign_key: { to_table: :solid_queue_workflows }
      t.string :active_job_id, null: false
      t.text :active_job, null: false
      t.string :workflow_level_id, null: false
      t.string :parent_workflow_level_id
      t.datetime :started_at, index: true
      t.datetime :finished_at, index: true
      t.datetime :discarded_at, index: true
      t.timestamps
    end

    add_index :solid_queue_workflow_levels, %i[workflow_level_id], unique: true
  end
end
