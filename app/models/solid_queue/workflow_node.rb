# frozen_string_literal: true

module SolidQueue
  class WorkflowNode < Record
    belongs_to :workflow

    serialize :active_job, coder: JSON

    scope :incomplete, -> { where(finished_at: nil, discarded_at: nil) }

    def self.descendants(workflow, workflow_level_id)
      workflow_id = workflow.id
      sql = <<-SQL
        WITH RECURSIVE descendants AS (
          SELECT id, workflow_level_id, parent_workflow_level_id, finished_at, discarded_at
          FROM solid_queue_workflow_nodes
          WHERE workflow_level_id = :workflow_level_id AND workflow_id = :workflow_id
          UNION ALL
          SELECT n.id, n.workflow_level_id, n.parent_workflow_level_id, n.finished_at, n.discarded_at
          FROM solid_queue_workflow_nodes n
          JOIN descendants d ON n.parent_workflow_level_id = d.workflow_level_id
        )
        SELECT * FROM descendants;
      SQL

      WorkflowNode.find_by_sql([sql, workflow_level_id: workflow_level_id, workflow_id: workflow_id])
    end

    def incomplete?
      finished_at.blank? && discarded_at.blank?
    end
  end
end
