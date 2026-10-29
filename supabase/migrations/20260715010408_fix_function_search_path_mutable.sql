-- ============================================================
-- SB-273: Fix function_search_path_mutable warnings
-- Using search_path = 'public' because function bodies reference
-- tables without schema qualification (wip_limits, work_items,
-- agents, activity_log)
-- ============================================================

ALTER FUNCTION public.enforce_wip_limit() SET search_path = 'public';
ALTER FUNCTION public.track_review_entry() SET search_path = 'public';
ALTER FUNCTION public.notify_wip_slot_opened() SET search_path = 'public';
ALTER FUNCTION public.enforce_done_gate() SET search_path = 'public';;
