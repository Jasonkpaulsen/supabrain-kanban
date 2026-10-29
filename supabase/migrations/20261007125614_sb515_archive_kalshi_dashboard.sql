-- SB-515 item 2 (Jason, 2026-10-07): take the Kalshi dashboard down and archive it.
-- The dashboard's only backend is public.kelshe_dashboard(). SB-366 already revoked
-- every non-admin grant; this removes the last API role (service_role) so nothing
-- outside a database owner session can call it. The function, trade_log and
-- trade_signals are kept (archived, not removed) and the KEL project is marked
-- archived. Reversible with one GRANT, but read the function comment first: it must
-- gain a user predicate before any grant is restored.

revoke all on function public.kelshe_dashboard() from service_role;
comment on function public.kelshe_dashboard() is
  'ARCHIVED (Jason, 2026-10-07, SB-515): the Kalshi dashboard is taken down; no API role may execute this. History: DORMANT since SB-366 (2026-08-19) — it was SECURITY DEFINER and read public.trade_log with NO user predicate, so any authenticated caller received another user''s trade rows. If Kalshi is ever revived, add a user predicate (or make it SECURITY INVOKER so RLS applies) BEFORE restoring any grant.';

update public.projects set status = 'archived', automation_status = 'paused'
 where project_key = 'KEL' and archived;

do $chk$
begin
  if has_function_privilege('anon', 'public.kelshe_dashboard()', 'execute')
     or has_function_privilege('authenticated', 'public.kelshe_dashboard()', 'execute')
     or has_function_privilege('service_role', 'public.kelshe_dashboard()', 'execute') then
    raise exception 'A1: an API role can still execute kelshe_dashboard()';
  end if;
  if not exists (select 1 from public.projects where project_key = 'KEL' and archived and status = 'archived') then
    raise exception 'A2: the KEL project is not archived';
  end if;
end $chk$;
