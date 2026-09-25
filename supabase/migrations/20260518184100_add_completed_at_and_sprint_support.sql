
-- Step 1: Add completed_at column
ALTER TABLE work_items ADD COLUMN IF NOT EXISTS completed_at timestamptz DEFAULT NULL;

-- Backfill existing done items
UPDATE work_items SET completed_at = updated_at WHERE status = 'done' AND completed_at IS NULL;

-- Step 2: Replace move_work_item to handle completed_at
CREATE OR REPLACE FUNCTION move_work_item(p_item_id uuid, p_new_status text, p_new_sort_order integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM work_items WHERE id = p_item_id AND user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  UPDATE work_items
  SET status = p_new_status,
      sort_order = p_new_sort_order,
      updated_at = now(),
      completed_at = CASE
        WHEN p_new_status = 'done' THEN COALESCE(completed_at, now())
        ELSE NULL
      END
  WHERE id = p_item_id;
END;
$$;

REVOKE ALL ON FUNCTION move_work_item(uuid, text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION move_work_item(uuid, text, integer) TO authenticated;

-- Step 3: Drop and recreate view with completed_at in correct position
DROP VIEW IF EXISTS kanban_board_view;

CREATE VIEW kanban_board_view AS
SELECT
  w.id, w.project_id, w.user_id, w.title, w.description, w.status, w.priority,
  w.sort_order, w.assignee, w.due_date, w.source_table, w.source_id,
  w.created_at, w.updated_at, w.completed_at,
  p.name AS project_name, p.icon AS project_icon,
  COALESCE(
    (SELECT jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name, 'color', l.color))
     FROM work_item_labels wl JOIN labels l ON l.id = wl.label_id
     WHERE wl.work_item_id = w.id), '[]'::jsonb
  ) AS labels,
  (SELECT count(*) FROM work_item_comments c WHERE c.work_item_id = w.id) AS comment_count
FROM work_items w
JOIN projects p ON p.id = w.project_id;
;
