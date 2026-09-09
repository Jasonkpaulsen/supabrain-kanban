-- SB-412: structured metrics with no sensitive payload.
-- security_invoker so the view cannot become the SB-431 defect all over again: it must
-- see exactly what the caller's own RLS allows, never the owner's view of the world.
create or replace view public.external_connection_activity_metrics
with (security_invoker = true) as
select
  a.connection_id,
  date_trunc('hour', a.created_at) as hour,
  a.tool_name,
  a.outcome,
  a.reason_code,
  count(*)                as events,
  sum(coalesce(a.result_rows,0)) as rows_returned
from public.external_connection_audit_log a
group by 1,2,3,4,5;

comment on view public.external_connection_activity_metrics is
  'SB-412. Counts only. Carries no identifiers beyond the connection and no payload of any '
  'kind. security_invoker = true so RLS on the underlying table still applies (SB-431).';

revoke all on public.external_connection_activity_metrics from public, anon, authenticated;
grant select on public.external_connection_activity_metrics to authenticated, service_role;