-- SB-409 / SB-431: the eight SECURITY DEFINER views flagged by the security advisor
-- ran as their owner and ignored every caller's RLS, so anon, any authenticated
-- uid and the SB-409 OAuth client could read every work item (1383 rows) and the
-- full agent roster through them. security_invoker makes each view evaluate the
-- caller's RLS on the underlying tables. Verified in a rolled-back dry run:
-- anon -> nothing, no-membership uid -> 0, Mandy -> her 108 member items,
-- Jason -> unchanged, service_role (agents via the hosted MCP) -> unchanged.
alter view public.kanban_board_view              set (security_invoker = true);
alter view public.v_empty_epics                  set (security_invoker = true);
alter view public.v_review_breaches_by_assignee  set (security_invoker = true);
alter view public.v_review_dwell_alerts          set (security_invoker = true);
alter view public.vw_agent_onboarding_gaps       set (security_invoker = true);
alter view public.vw_agent_onboarding_violations set (security_invoker = true);
alter view public.vw_agent_roster_status         set (security_invoker = true);
alter view public.vw_review_sla                  set (security_invoker = true);

-- Views are read surfaces; nothing should INSERT/UPDATE/DELETE through them and
-- anon has no business on the governance views at all.
revoke insert, update, delete, truncate, references, trigger on
  public.kanban_board_view, public.v_empty_epics, public.v_review_breaches_by_assignee,
  public.v_review_dwell_alerts, public.vw_agent_onboarding_gaps, public.vw_agent_onboarding_violations,
  public.vw_agent_roster_status, public.vw_review_sla
from anon, authenticated;
revoke all on
  public.v_empty_epics, public.v_review_breaches_by_assignee, public.v_review_dwell_alerts,
  public.vw_agent_onboarding_gaps, public.vw_agent_onboarding_violations, public.vw_agent_roster_status, public.vw_review_sla
from anon;