-- OPS-001: Fix SECURITY DEFINER functions per Architect directive
-- Convert move_work_item and assign_agent_to_item to SECURITY INVOKER (they have internal auth checks)
-- Keep get_dashboard_activity, get_schema_info, get_table_counts as SECURITY DEFINER but lock down access

-- move_work_item → SECURITY INVOKER
CREATE OR REPLACE FUNCTION public.move_work_item(p_item_id uuid, p_new_status text, p_new_sort_order integer)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO ''
AS $function$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.work_items WHERE id = p_item_id AND user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  UPDATE public.work_items
  SET status = p_new_status,
      sort_order = p_new_sort_order,
      updated_at = now(),
      completed_at = CASE
        WHEN p_new_status = 'done' THEN COALESCE(completed_at, now())
        ELSE NULL
      END
  WHERE id = p_item_id;
END;
$function$;

-- assign_agent_to_item → SECURITY INVOKER
CREATE OR REPLACE FUNCTION public.assign_agent_to_item(p_item_id uuid, p_agent_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO ''
AS $function$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.work_items WHERE id = p_item_id AND user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Not authorized to modify this item';
  END IF;
  
  IF p_agent_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.agents WHERE id = p_agent_id AND user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Agent not found or not authorized';
  END IF;

  UPDATE public.work_items
  SET assigned_agent_id = p_agent_id,
      updated_at = now()
  WHERE id = p_item_id;
END;
$function$;

-- Lock down the 3 SECURITY DEFINER functions that must stay DEFINER
REVOKE EXECUTE ON FUNCTION public.get_dashboard_activity(integer) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_dashboard_activity(integer) TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.get_schema_info() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_schema_info() TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.get_table_counts() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_table_counts() TO authenticated, service_role;;
