-- SB-601..604 verifier minors (ADR-FLOW-005 amendment 1).
--  1. v_open_work_wait_state: SELECT only for service_role, as D3a says. Supabase default
--     privileges had granted it every privilege, and the view is auto-updatable.
--  4. Object comments describe D2a / D3a; the v_external_wait_status comment predated D2a.

revoke all on public.v_open_work_wait_state from service_role;
grant select on public.v_open_work_wait_state to service_role;

comment on view public.v_external_wait_status is
  'SB-593 / SB-603, ADR-FLOW-005 D2 and D2a: open, non-archived items waiting on an outside party. '
  'severity escalate = clock lapsed (wins), data_quality = data_quality_issue set (invalid_clock, '
  'non_text_party, no_clock), info = on track. clock_source due_date_fallback = an invalid meta clock fell back to due_date.';
comment on view public.v_open_work_wait_state is
  'SB-601 / SB-602, ADR-FLOW-005 D3a: open, non-archived work items with wait_state = work_item_wait_state(meta, due_date). '
  'Read by supabrain-sweep stale_wip, blocked_items and review_queue_aging (wait_state is null). SELECT for service_role only.';
comment on function public.external_wait_data_quality(jsonb, date) is
  'SB-603, ADR-FLOW-005 D2a: NULL or the first of invalid_clock, non_text_party, no_clock. Meaningful for a waiting item. '
  'Does not change work_item_wait_state.';

do $assert$
begin
  if (select relacl::text from pg_class where oid = 'public.v_open_work_wait_state'::regclass)
     is distinct from '{postgres=arwdDxtm/postgres,service_role=r/postgres}'
     or has_table_privilege('anon', 'public.v_open_work_wait_state', 'select')
     or has_table_privilege('authenticated', 'public.v_open_work_wait_state', 'select') then
    raise exception 'SB-602: v_open_work_wait_state grants are not SELECT-for-service_role-only';
  end if;
  if obj_description('public.v_external_wait_status'::regclass, 'pg_class') not like '%D2a%'
     or obj_description('public.v_open_work_wait_state'::regclass, 'pg_class') is null
     or obj_description('public.external_wait_data_quality(jsonb,date)'::regprocedure, 'pg_proc') is null then
    raise exception 'SB-603: object comments missing';
  end if;
end
$assert$;
