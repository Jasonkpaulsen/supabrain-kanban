-- SB-235: Convert 8 SECURITY DEFINER views to SECURITY INVOKER
-- These views are read-only SELECTs over RLS-protected tables.
-- None depend on SECURITY DEFINER behavior; converting ensures
-- the querying user's RLS is respected.

ALTER VIEW public.vw_audit_health_checks SET (security_invoker = on);
ALTER VIEW public.v_review_sla_breaches SET (security_invoker = on);
ALTER VIEW public.v_backlog_grooming_queue SET (security_invoker = on);
ALTER VIEW public.v_grooming_schedule SET (security_invoker = on);
ALTER VIEW public.v_orphan_tasks SET (security_invoker = on);
ALTER VIEW public.v_wip_aging_alerts SET (security_invoker = on);
ALTER VIEW public.v_gate_leak_alerts SET (security_invoker = on);
ALTER VIEW public.v_qa_coverage_authoritative SET (security_invoker = on);;
