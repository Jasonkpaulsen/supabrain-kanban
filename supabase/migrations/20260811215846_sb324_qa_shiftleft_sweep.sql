-- SB-324: the QA gate fires at done — the worst moment to learn tests are missing.
-- This sweep moves the signal to the start of work. ADVISORY ONLY: it stamps meta and
-- writes one briefing line; it never blocks a write path (that stays SB-322's job).
create or replace function public.qa_shiftleft_sweep()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_flagged jsonb;
  v_cleared int;
  v_summary text;
begin
  -- Flag: QA-gated tickets actively being worked (in_progress/review) with zero test cases.
  -- Exemption ladder mirrors enforce_qa_gate (spec §8.2) so exempt tickets never appear.
  with gated as (
    select w.id, w.ticket_code, w.assignee
    from work_items w join projects p on p.id=w.project_id
    where not w.archived and w.status in ('in_progress','review')
      and p.domain in ('products','operations','prediction-markets')
      and w.type not in ('epic','chore','spike','requirement')
      and not coalesce((w.meta->>'qa_gate_exempt')::boolean,false)
      and not (w.title ~* '\m(design|mockup|wireframe|prototype|layout|visual)\M' or w.title ~* '\mIA\M')
      and not exists (select 1 from test_cases t where t.work_item_id=w.id)
  ), stamped as (
    update work_items w set
      meta = coalesce(w.meta,'{}'::jsonb) || jsonb_build_object('qa_missing_tests', now()::text)
    from gated g where w.id=g.id
    returning g.ticket_code, g.assignee
  )
  select coalesce(jsonb_agg(jsonb_build_object('ticket',ticket_code,'assignee',assignee)),'[]'::jsonb)
    into v_flagged from stamped;

  -- Clear: previously flagged tickets that now have tests (or left active work).
  with clearable as (
    select w.id from work_items w
    where w.meta ? 'qa_missing_tests'
      and (exists (select 1 from test_cases t where t.work_item_id=w.id)
           or w.status not in ('in_progress','review'))
  )
  update work_items w set meta = w.meta - 'qa_missing_tests'
  from clearable c where w.id=c.id;
  get diagnostics v_cleared = ROW_COUNT;

  v_summary := case
    when jsonb_array_length(v_flagged)=0
      then format('QA shift-left: all clear — every active gated ticket has test cases (%s flag(s) cleared).', v_cleared)
    else format('QA shift-left: %s active ticket(s) working without test cases — tests are due at start of work, not at done. %s flag(s) cleared.',
                jsonb_array_length(v_flagged), v_cleared)
  end;

  insert into activity_log (project_id, user_id, agent_name, action, target_table, summary, meta)
  values ('a07a7f3d-722f-468f-81fa-84e2c5fba704','5ecbd44a-a3e2-4363-9133-dff3851ba0f5',
          'System','commented','work_items', v_summary,
          jsonb_build_object('artifact','qa_shiftleft','flagged',v_flagged,'cleared',v_cleared));

  return jsonb_build_object('summary',v_summary,'flagged',v_flagged,'cleared',v_cleared);
end $$;

revoke execute on function public.qa_shiftleft_sweep() from anon, authenticated, public;

select cron.schedule('qa-shiftleft-daily', '45 7 * * *', $$select public.qa_shiftleft_sweep()$$);;
