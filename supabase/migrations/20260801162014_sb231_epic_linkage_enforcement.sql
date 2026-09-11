
-- SB-231: Require epic linkage on tasks/chores

-- 1. Create catch-all epic for WW (only active project with items missing one)
INSERT INTO work_items (project_id, user_id, title, type, status, priority, approval_status, sort_order, meta)
VALUES (
  'fc12912d-1bdd-427e-a799-3fa9d857f58a',
  '5ecbd44a-a3e2-4363-9133-dff3851ba0f5',
  'Catch-All — Unsorted (WW)',
  'epic', 'backlog', 'low', 'not_required', 9999,
  jsonb_build_object('catch_all', true, 'created_by', 'SB-231-migration')
);

-- 2. Extend trigger to also fire on UPDATE (prevent parent_id being nulled)
-- The existing function already handles the logic; just add the UPDATE event
DROP TRIGGER IF EXISTS trg_epic_linkage ON work_items;
CREATE TRIGGER trg_epic_linkage
  BEFORE INSERT OR UPDATE ON work_items
  FOR EACH ROW
  EXECUTE FUNCTION enforce_epic_linkage();

-- 3. Create a view to monitor orphan health
CREATE OR REPLACE VIEW v_orphan_tasks AS
SELECT
  wi.id,
  wi.ticket_code,
  wi.title,
  wi.type,
  wi.status,
  p.project_key,
  p.name AS project_name,
  wi.created_at
FROM work_items wi
JOIN projects p ON p.id = wi.project_id
WHERE wi.type IN ('task','chore')
  AND wi.parent_id IS NULL
ORDER BY wi.created_at DESC;
;
