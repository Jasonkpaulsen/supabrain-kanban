-- PART 1: Parent/child nesting
ALTER TABLE work_items ADD COLUMN parent_id UUID REFERENCES work_items(id) ON DELETE SET NULL;
CREATE INDEX idx_work_items_parent ON work_items (parent_id) WHERE parent_id IS NOT NULL;

COMMENT ON COLUMN work_items.parent_id IS 'Parent ticket for nesting. Typical use: epic (parent) → tasks/stories (children). Supports multi-level but keep to 2 in practice.';

-- PART 2: Work item links (dependencies, relations)
CREATE TABLE work_item_links (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  from_item_id UUID NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
  to_item_id UUID NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
  link_type TEXT NOT NULL CHECK (link_type IN ('blocks', 'blocked_by', 'relates_to', 'duplicates')),
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(from_item_id, to_item_id, link_type),
  CHECK (from_item_id != to_item_id)
);

CREATE INDEX idx_wil_from ON work_item_links (from_item_id);
CREATE INDEX idx_wil_to ON work_item_links (to_item_id);

ALTER TABLE work_item_links ENABLE ROW LEVEL SECURITY;

CREATE POLICY service_role_full ON work_item_links FOR ALL TO service_role USING (true);
CREATE POLICY users_select_own ON work_item_links FOR SELECT TO authenticated
  USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_insert_own ON work_item_links FOR INSERT TO authenticated
  WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY users_delete_own ON work_item_links FOR DELETE TO authenticated
  USING ((SELECT auth.uid()) = user_id);

COMMENT ON TABLE work_item_links IS 'Directional links between tickets: blocks, blocked_by, relates_to, duplicates. Use for dependency tracking and cross-referencing.';

-- PART 3: Update kanban_board_view with nesting and link data
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
    w.parent_id,
    parent.title AS parent_title,
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
          WHERE c.work_item_id = w.id) AS comment_count,
    ( SELECT count(*)
           FROM work_items child
          WHERE child.parent_id = w.id) AS child_count,
    ( SELECT count(*)
           FROM work_items child
          WHERE child.parent_id = w.id AND child.status = 'done') AS completed_child_count,
    ( SELECT count(*)
           FROM work_item_links wil
             JOIN work_items blocker ON blocker.id = wil.from_item_id
          WHERE wil.to_item_id = w.id 
            AND wil.link_type = 'blocks' 
            AND blocker.status != 'done') AS blocked_by_count
   FROM work_items w
     JOIN projects p ON p.id = w.project_id
     LEFT JOIN agents a ON a.id = w.assigned_agent_id
     LEFT JOIN work_items parent ON parent.id = w.parent_id;;
