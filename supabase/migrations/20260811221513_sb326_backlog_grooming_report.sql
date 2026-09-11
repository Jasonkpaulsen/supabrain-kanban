-- SB-326: intake outruns completion (294 vs 170 per 28d) and 200+ backlog items sit
-- untouched for weeks. This is a DRY-RUN reporter in the archive_work_items mould:
-- it proposes, a human disposes. It never mutates work_items.
create or replace function public.backlog_grooming_report(p_stale_days integer default 45)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_items jsonb; v_count int; v_summary text;
begin
  with stale as (
    select w.ticket_code, w.title, w.priority, p.name as project,
           extract(day from now()-w.updated_at)::int as days_untouched,
           case
             when w.priority in ('critical','high') then 'keep — high priority; re-plan it'
             when extract(day from now()-w.updated_at) >= 90 then 'close — untouched a quarter; if it mattered it would have moved'
             when extract(day from now()-w.updated_at) >= 60 then 'park — move to on_hold pending an owner'
             else 'keep — review at next grooming'
           end as proposal
    from work_items w join projects p on p.id=w.project_id
    where not w.archived and w.status='backlog'
      and w.updated_at < now() - make_interval(days => p_stale_days)
      and not (w.meta ? 'grooming_disposed')
  )
  select coalesce(jsonb_agg(to_jsonb(s) order by s.days_untouched desc),'[]'::jsonb), count(*)
    into v_items, v_count from stale s;

  v_summary := case when v_count=0
    then 'Backlog grooming: all clear — no undisposed backlog item untouched over '||p_stale_days||' days.'
    else format('Backlog grooming: %s backlog item(s) untouched >%s days await disposition (park/close/keep). DRY RUN — nothing was changed.', v_count, p_stale_days) end;

  insert into activity_log (project_id,user_id,agent_name,action,target_table,summary,meta)
  values ('a07a7f3d-722f-468f-81fa-84e2c5fba704','5ecbd44a-a3e2-4363-9133-dff3851ba0f5',
          'System','commented','work_items', v_summary,
          jsonb_build_object('artifact','backlog_grooming','stale_days',p_stale_days,'count',v_count,'items',v_items));

  return jsonb_build_object('summary',v_summary,'count',v_count,'items',v_items);
end $$;

revoke execute on function public.backlog_grooming_report(integer) from anon, authenticated, public;

select cron.schedule('backlog-grooming-weekly', '5 8 * * 1', $$select public.backlog_grooming_report(45)$$);;
