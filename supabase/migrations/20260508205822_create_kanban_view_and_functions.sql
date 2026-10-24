
-- Step 6: Kanban board view — joins labels + comment count onto each work item
CREATE OR REPLACE VIEW public.kanban_board_view AS
SELECT
  wi.id,
  wi.project_id,
  wi.user_id,
  wi.title,
  wi.description,
  wi.status,
  wi.priority,
  wi.sort_order,
  wi.assignee,
  wi.due_date,
  wi.source_table,
  wi.source_id,
  wi.created_at,
  wi.updated_at,
  p.name AS project_name,
  p.icon AS project_icon,
  COALESCE(
    (SELECT jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name, 'color', l.color))
     FROM public.work_item_labels wil
     JOIN public.labels l ON l.id = wil.label_id
     WHERE wil.work_item_id = wi.id),
    '[]'::jsonb
  ) AS labels,
  COALESCE(
    (SELECT count(*) FROM public.work_item_comments wic WHERE wic.work_item_id = wi.id),
    0
  ) AS comment_count
FROM public.work_items wi
JOIN public.projects p ON p.id = wi.project_id;

-- Function: atomic move for drag-and-drop
CREATE OR REPLACE FUNCTION public.move_work_item(
  p_item_id uuid,
  p_new_status text,
  p_new_sort_order integer
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Verify ownership
  IF NOT EXISTS (
    SELECT 1 FROM public.work_items WHERE id = p_item_id AND user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  -- Shift existing items down in the target column to make room
  UPDATE public.work_items
  SET sort_order = sort_order + 1,
      updated_at = now()
  WHERE user_id = auth.uid()
    AND id != p_item_id
    AND status = p_new_status
    AND sort_order >= p_new_sort_order;

  -- Move the item
  UPDATE public.work_items
  SET status = p_new_status,
      sort_order = p_new_sort_order,
      updated_at = now()
  WHERE id = p_item_id
    AND user_id = auth.uid();
END;
$$;

-- Revoke from PUBLIC, grant only to authenticated
REVOKE EXECUTE ON FUNCTION public.move_work_item(uuid, text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.move_work_item(uuid, text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.move_work_item(uuid, text, integer) TO service_role;
;
