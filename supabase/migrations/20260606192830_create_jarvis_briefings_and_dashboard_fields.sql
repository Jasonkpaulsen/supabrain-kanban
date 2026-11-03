-- 1. jarvis_briefings: AI intelligence layer only
CREATE TABLE jarvis_briefings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  briefing_date DATE NOT NULL,
  narrative_summary TEXT,
  recommendations JSONB DEFAULT '[]'::jsonb,
  flags JSONB DEFAULT '[]'::jsonb,
  meta JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(user_id, briefing_date)
);

CREATE INDEX idx_jarvis_briefings_date ON jarvis_briefings (briefing_date DESC);

CREATE TRIGGER trigger_update_updated_at
  BEFORE UPDATE ON jarvis_briefings
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- Auto-purge: delete rows older than 7 days on INSERT
CREATE OR REPLACE FUNCTION purge_old_briefings()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO ''
AS $function$
BEGIN
  DELETE FROM public.jarvis_briefings
  WHERE user_id = NEW.user_id
  AND briefing_date < CURRENT_DATE - INTERVAL '7 days';
  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_purge_old_briefings
  AFTER INSERT ON jarvis_briefings
  FOR EACH ROW EXECUTE FUNCTION purge_old_briefings();

ALTER TABLE jarvis_briefings ENABLE ROW LEVEL SECURITY;
CREATE POLICY service_role_full ON jarvis_briefings FOR ALL TO service_role USING (true);
CREATE POLICY users_select_own ON jarvis_briefings FOR SELECT TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_insert_own ON jarvis_briefings FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY users_update_own ON jarvis_briefings FOR UPDATE TO authenticated USING ((SELECT auth.uid()) = user_id);

COMMENT ON TABLE jarvis_briefings IS 'JARVIS AI intelligence layer: narrative summary, recommendations, and pattern-detected flags. One row per day, auto-purged after 7 days. Dashboard reads live data from existing tables — this table stores only what AI analysis produces.';

-- 2. Add dashboard interaction fields to work_items
ALTER TABLE work_items ADD COLUMN acknowledged BOOLEAN DEFAULT false;
ALTER TABLE work_items ADD COLUMN acknowledged_at TIMESTAMPTZ;
ALTER TABLE work_items ADD COLUMN snoozed_until DATE;

COMMENT ON COLUMN work_items.acknowledged IS 'Jason has seen and acknowledged this item via the JARVIS dashboard';
COMMENT ON COLUMN work_items.snoozed_until IS 'Item hidden from dashboard until this date, then auto-returns';

-- 3. Add dashboard interaction fields to job_applications
ALTER TABLE job_applications ADD COLUMN acknowledged BOOLEAN DEFAULT false;
ALTER TABLE job_applications ADD COLUMN acknowledged_at TIMESTAMPTZ;
ALTER TABLE job_applications ADD COLUMN snoozed_until DATE;

-- 4. Update kanban_board_view with new columns
DROP VIEW IF EXISTS kanban_board_view;
CREATE VIEW kanban_board_view WITH (security_invoker = true) AS
SELECT w.id,
    w.project_id,
    w.user_id,
    w.ticket_code,
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
    w.acknowledged,
    w.acknowledged_at,
    w.snoozed_until,
    parent.title AS parent_title,
    p.name AS project_name,
    p.icon AS project_icon,
    p.project_key,
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
