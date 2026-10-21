-- SB-622: escalate_overdue_reviews(uuid) is SECURITY DEFINER and lost its pinned search_path when
-- the SB-303 migrations (20260815173923, 20260815174231) dropped and recreated it. Re-sent with
-- search_path = '' and both relations schema-qualified; signature, return type, body logic and
-- grants are unchanged. The closing check also asserts the class: no SECURITY DEFINER function in
-- public may lack a pinned search_path, so a future recreate without SET fails here.

create or replace function public.escalate_overdue_reviews(p_user_id uuid default null::uuid)
 returns table(ticket_code text, title text, hours_in_review numeric, sla_status text, assignee text, project_name text)
 language plpgsql
 security definer
 set search_path = ''
as $function$
BEGIN
  RETURN QUERY
  SELECT
    v.ticket_code,
    v.title,
    v.hours_in_review,
    v.sla_status,
    v.assignee,
    v.project_name
  FROM public.vw_review_sla v
  JOIN public.work_items w ON w.id = v.id
  WHERE v.sla_breached = true
    AND (p_user_id IS NULL OR w.user_id = p_user_id)
  ORDER BY v.hours_in_review DESC;
END;
$function$;

comment on function public.escalate_overdue_reviews(uuid) is
  'SB-085 review SLA escalation list. SECURITY DEFINER with search_path pinned to '''' (SB-622); every relation is schema-qualified.';

do $assert$
declare n int; v_list text;
begin
  if not exists (select 1 from pg_proc where oid = 'public.escalate_overdue_reviews(uuid)'::regprocedure
                   and prosecdef and proconfig = array['search_path=""'])
     or has_function_privilege('anon', 'public.escalate_overdue_reviews(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.escalate_overdue_reviews(uuid)', 'execute')
     or not has_function_privilege('service_role', 'public.escalate_overdue_reviews(uuid)', 'execute') then
    raise exception 'SB-622: escalate_overdue_reviews posture';
  end if;
  select count(*), string_agg(p.oid::regprocedure::text, ', ') into n, v_list
    from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.prosecdef
     and not exists (select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) c where c like 'search_path=%')
     and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e');
  if n <> 0 then raise exception 'SB-622: % SECURITY DEFINER function(s) in public without a pinned search_path: %', n, v_list; end if;
end
$assert$;
