-- OPS-002: Add approval tracking columns to work_items

ALTER TABLE work_items ADD COLUMN approved_by TEXT;
ALTER TABLE work_items ADD COLUMN approved_at TIMESTAMPTZ;
ALTER TABLE work_items ADD COLUMN approval_status TEXT NOT NULL DEFAULT 'not_required'
  CHECK (approval_status IN ('pending', 'approved', 'rejected', 'not_required'));

CREATE INDEX idx_work_items_approval_pending ON work_items (approval_status) 
  WHERE approval_status = 'pending';

COMMENT ON COLUMN work_items.approved_by IS 'Name of the agent or person who approved this ticket (e.g. CIP Architect, System Architect, Jason)';
COMMENT ON COLUMN work_items.approved_at IS 'Timestamp when the ticket was approved';
COMMENT ON COLUMN work_items.approval_status IS 'Approval gate: pending (needs approval), approved (cleared to execute), rejected (sent back), not_required (no approval needed)';

-- Recreate kanban_board_view with approval columns (preserve SECURITY INVOKER)
DROP VIEW IF EXISTS kanban_board_view;
CREATE VIEW kanban_board_view WITH (security_invoker = true) AS
SELECT w.id,
    w.project_id,
    w.user_id,
    w.title,
    w.description,
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
