-- Add ticket type classification
ALTER TABLE work_items ADD COLUMN type TEXT NOT NULL DEFAULT 'task'
  CHECK (type IN ('task', 'bug', 'user_story', 'spike', 'chore', 'epic', 'requirement'));

CREATE INDEX idx_work_items_type ON work_items (type);

COMMENT ON COLUMN work_items.type IS 'Ticket type: task (default), bug (defect), user_story (BA requirement), spike (research/investigation), chore (maintenance/ops), epic (decomposes into subtasks), requirement (formal BA requirement with acceptance criteria)';

-- Recreate kanban_board_view with type column
DROP VIEW IF EXISTS kanban_board_view;
CREATE VIEW kanban_board_view WITH (security_invoker = true) AS
SELECT w.id,
    w.project_id,
    w.user_id,
    w.title,
    w.description,
    w.type,
    w.status,
    w.priority,
    w.sort_order,
    w.assignee,
    w.due_date,
    w.source_table,
    w.source_id,
    w.created_at,
    w.updated_at,
    w.completed_at,
    w.assigned_agent_id,
    w.approved_by,
    w.approved_at,
    w.approval_status,
    p.name AS project_name,
    p.icon AS project_icon,
    a.name AS agent_name,
    a.icon AS agent_icon,
    a.status AS agent_status,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name, 'color', l.color))
           FROM work_item_labels wl
             JOIN labels l ON l.id = wl.label_id
          WHERE wl.work_item_id = w.id), '[]'::jsonb) AS labels,
    ( SELECT count(*)
           FROM work_item_comments c
          WHERE c.work_item_id = w.id) AS comment_count
   FROM work_items w
     JOIN projects p ON p.id = w.project_id
     LEFT JOIN agents a ON a.id = w.assigned_agent_id;;
