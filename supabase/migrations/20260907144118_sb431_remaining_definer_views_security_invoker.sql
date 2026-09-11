-- SB-431: the remaining eight SECURITY DEFINER views over work_items carry the same
-- anon/authenticated grants as the flagged set and bypass RLS the same way.
-- Consumers are platform agents through the hosted MCP (service_role), which is unaffected.
alter view public.v_backlog_grooming_queue    set (security_invoker = true);
alter view public.v_gate_leak_alerts          set (security_invoker = true);
alter view public.v_grooming_schedule         set (security_invoker = true);
alter view public.v_orphan_tasks              set (security_invoker = true);
alter view public.v_qa_coverage_authoritative set (security_invoker = true);
alter view public.v_review_sla_breaches       set (security_invoker = true);
alter view public.v_wip_aging_alerts          set (security_invoker = true);
alter view public.vw_audit_health_checks      set (security_invoker = true);
revoke all on
  public.v_backlog_grooming_queue, public.v_gate_leak_alerts, public.v_grooming_schedule, public.v_orphan_tasks,
  public.v_qa_coverage_authoritative, public.v_review_sla_breaches, public.v_wip_aging_alerts, public.vw_audit_health_checks
from anon;
revoke insert, update, delete, truncate, references, trigger on
  public.v_backlog_grooming_queue, public.v_gate_leak_alerts, public.v_grooming_schedule, public.v_orphan_tasks,
  public.v_qa_coverage_authoritative, public.v_review_sla_breaches, public.v_wip_aging_alerts, public.vw_audit_health_checks
from authenticated;;
