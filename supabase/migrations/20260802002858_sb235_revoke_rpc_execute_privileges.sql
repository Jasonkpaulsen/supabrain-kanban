-- SB-235: Revoke EXECUTE from anon/authenticated on SECURITY DEFINER RPCs
-- Per ticket + advisor findings (lint 0028/0029)

-- === REVOKE anon from ticket-listed RPCs ===
-- (generate_daily_audit and kelshe_dashboard already have anon revoked)
REVOKE EXECUTE ON FUNCTION public.articles_touch() FROM anon;
REVOKE EXECUTE ON FUNCTION public.is_project_member(uuid, uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.is_project_owner(uuid, uuid) FROM anon;

-- === REVOKE authenticated from ticket-listed RPCs ===
-- (get_schema_info and get_table_counts already have authenticated revoked)
REVOKE EXECUTE ON FUNCTION public.finish_agent_run(uuid, text, integer, integer, integer, integer, integer, integer, text, text, text, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.start_agent_run(uuid, uuid, uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.get_dashboard_activity(integer) FROM authenticated;

-- === Additional advisor findings: internal/cron SECURITY DEFINER functions ===
-- watch_ functions are one-shot cron helpers, not user-facing RPCs
REVOKE EXECUTE ON FUNCTION public.watch_cip154_dispatch149() FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.watch_cip165_dispatch166() FROM anon, authenticated;
-- audit_approval_reversal is a trigger function, not user-callable
REVOKE EXECUTE ON FUNCTION public.audit_approval_reversal() FROM anon, authenticated;;
