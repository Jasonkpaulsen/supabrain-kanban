-- SB-607 part 3: the SB-554 digest verifier fixes pinned by supabase/tests/jason_decision_digest_suite.sql.
--  1. escalation_subject_codes also reads meta.escalates (string) and meta.related (string or array).
--  2. The classifier stamps meta.subject_class, and enforce mode refuses only when the subject itself
--     waits on Jason (an L3 or flagged escalation about an agent subject is accepted).
--  3. The title rule is ~* '^\s*ESCALATION' in the classifier, the digest view and the no-op count.
--  4. vw_jason_decision_digest gains row_kind ('item' | 'orphan_escalation'), appended last, and
--     attaches each folded escalation to exactly one subject row: a primary code (blocker_ref,
--     upstream_ticket, escalates) when one is a digest row, else the first matching code. Before
--     this, a multi-subject escalation (SB-553) was attached under every matching row.
--     jason_decision_digest() returns row_kind per item and an orphan_escalations count.
-- Gate modes are unchanged (warn).

create or replace function public.escalation_subject_codes(p_meta jsonb)
  returns text[] language sql immutable set search_path = public as $$
  select coalesce(array_agg(distinct c order by c), '{}'::text[])
    from (
      select upper(btrim(v)) as c
        from (
          select p_meta->>'blocker_ref' as v
          union all
          select p_meta->>'upstream_ticket'
          union all
          select case when jsonb_typeof(p_meta->'escalates') = 'string' then p_meta->>'escalates' end
          union all
          select case when jsonb_typeof(p_meta->'related') = 'string' then p_meta->>'related' end
          union all
          select e from jsonb_array_elements_text(
            case when jsonb_typeof(p_meta->'related') = 'array' then p_meta->'related' else '[]'::jsonb end) e
          union all
          select e from jsonb_array_elements_text(
            case when jsonb_typeof(p_meta->'related_tickets') = 'array' then p_meta->'related_tickets' else '[]'::jsonb end) e
          union all
          select e from jsonb_array_elements_text(
            case when jsonb_typeof(p_meta->'requires_jason') = 'array' then p_meta->'requires_jason' else '[]'::jsonb end) e
        ) s
       where v is not null
    ) t
   where c ~ '^[A-Z0-9]+-[0-9]+$'
$$;

create or replace function public.classify_escalation_on_insert()
  returns trigger language plpgsql set search_path = public as $$
declare
  v_subject text;
  v_class text;
begin
  if NEW.title is null or NEW.title !~* '^\s*ESCALATION' then
    return NEW;
  end if;
  begin
    v_subject := public.jason_blocker_class(public.escalation_subject_codes(NEW.meta));
    v_class := case
                 when coalesce(NEW.authority_level, 0) >= 3
                   or NEW.status = 'awaiting_jason'
                   or NEW.meta->>'flagged_for_jason' = 'true'
                 then 'human_decision'
                 else v_subject
               end;
    NEW.meta := coalesce(NEW.meta, '{}'::jsonb)
                || jsonb_build_object('blocker_class', v_class,
                                      'subject_class', v_subject,
                                      'digest_routed', v_class = 'human_decision',
                                      'classified_by', 'SB-554');
  exception when others then
    return NEW;
  end;
  -- refuse only the no-op case: the subject is already waiting on Jason
  if v_subject = 'human_decision' and public.escalation_gate_mode('SB-554') = 'enforce' then
    raise exception 'ESCALATION-003: route to the decision digest; the subject waits on Jason'
      using errcode = 'P0554', hint = 'select * from public.vw_jason_decision_digest';
  end if;
  return NEW;
end
$$;

create or replace view public.vw_jason_decision_digest with (security_invoker = true) as
with esc as (
  select e.id, e.user_id, e.ticket_code, e.authority_level,
         coalesce(e.meta->>'blocker_class',
                  case when coalesce(e.authority_level, 0) >= 3 or e.status = 'awaiting_jason' or e.meta->>'flagged_for_jason' = 'true'
                       then 'human_decision'
                       else public.jason_blocker_class(public.escalation_subject_codes(e.meta)) end) as blocker_class,
         public.escalation_subject_codes(e.meta) as subjects,
         public.escalation_subject_codes(jsonb_build_object('blocker_ref', e.meta->'blocker_ref',
                                                            'upstream_ticket', e.meta->'upstream_ticket',
                                                            'escalates', e.meta->'escalates')) as primary_subjects
    from public.work_items e
   where e.title ~* '^\s*ESCALATION' and e.status not in ('done', 'cancelled') and not e.archived
), folded as (
  select esc.id, esc.user_id, esc.ticket_code, esc.subjects, esc.primary_subjects
    from esc
   where esc.blocker_class = 'human_decision' or coalesce(esc.authority_level, 0) >= 3
), core as (
  select w.id, w.ticket_code, w.project_id, w.user_id, w.priority, w.status, w.authority_level,
         w.approval_status, w.title, w.meta, w.updated_at
    from public.work_items w
   where w.status not in ('done', 'cancelled') and not w.archived
     and (w.status = 'awaiting_jason'
          or (w.approval_status = 'pending' and (coalesce(w.authority_level, 1) >= 2 or w.meta ? 'proposal_type')))
     and not (nullif(btrim(w.meta->>'awaiting_external'), '') is not null
              and lower(btrim(w.meta->>'awaiting_external')) <> 'false')
     and not exists (select 1 from folded f where f.id = w.id)
), attach as (
  select distinct on (f.id) f.id, f.user_id, f.ticket_code, c.ticket_code as subject
    from folded f
    join core c on c.user_id = f.user_id and c.ticket_code = any (f.subjects)
   order by f.id, (c.ticket_code = any (f.primary_subjects)) desc, c.ticket_code
), orphan as (
  select w.id, w.ticket_code, w.project_id, w.user_id, w.priority, w.status, w.authority_level,
         w.approval_status, w.title, w.meta, w.updated_at
    from public.work_items w
    join folded f on f.id = w.id
   where not exists (select 1 from attach a where a.id = f.id)
), base as (
  select x.*,
         round(extract(epoch from now() - x.updated_at) / 86400::numeric, 1) as waiting_days,
         case x.priority when 'critical' then 3 when 'high' then 7 when 'medium' then 14 when 'low' then 30 else 14 end
           as aging_threshold_days,
         case x.priority when 'critical' then 1 when 'high' then 2 when 'medium' then 3 when 'low' then 4 else 5 end
           as priority_rank
    from (select core.*, 'item'::text as row_kind from core
          union all
          select orphan.*, 'orphan_escalation'::text from orphan) x
)
select b.ticket_code, b.project_id, b.user_id, b.priority, b.status, b.authority_level, b.approval_status, b.title,
       left(coalesce(b.meta->>'decision_needed', b.meta->>'blocked_on', b.meta->>'approval_note'), 200) as decision_needed,
       b.waiting_days,
       b.aging_threshold_days,
       b.waiting_days > b.aging_threshold_days::numeric as aging_breached,
       coalesce((select array_agg(a.ticket_code order by a.ticket_code)
                   from attach a
                  where a.user_id = b.user_id and a.subject = b.ticket_code), '{}'::text[]) as escalations_attached,
       row_number() over (partition by b.user_id order by b.priority_rank, b.waiting_days desc, b.ticket_code) as rank,
       b.row_kind
  from base b;

create or replace function public.jason_decision_digest()
  returns jsonb language sql stable set search_path = public as $$
  with d as (
    select * from public.vw_jason_decision_digest
     where auth.uid() is null or user_id = auth.uid()
  ),
  noop as (
    select count(*) as n
      from public.work_items e
     where e.title ~* '^\s*ESCALATION'
       and e.status not in ('done', 'cancelled')
       and not e.archived
       and (auth.uid() is null or e.user_id = auth.uid())
       and (coalesce(e.authority_level, 0) >= 3
            or coalesce(e.meta->>'blocker_class',
                        case
                          when e.status = 'awaiting_jason' or e.meta->>'flagged_for_jason' = 'true'
                          then 'human_decision'
                          else public.jason_blocker_class(public.escalation_subject_codes(e.meta))
                        end) = 'human_decision')
  )
  select jsonb_build_object(
           'total', (select count(*) from d),
           'by_priority', coalesce((select jsonb_object_agg(priority, n)
                                      from (select priority, count(*) as n from d group by priority) p), '{}'::jsonb),
           'breached', (select count(*) from d where aging_breached),
           'oldest_days', (select max(waiting_days) from d),
           'noop_escalations', (select n from noop),
           'orphan_escalations', (select count(*) from d where row_kind = 'orphan_escalation'),
           'items', coalesce((select jsonb_agg(jsonb_build_object(
                                       'rank', rank, 'ticket_code', ticket_code, 'priority', priority,
                                       'status', status, 'authority_level', authority_level,
                                       'approval_status', approval_status, 'title', title,
                                       'decision_needed', decision_needed, 'waiting_days', waiting_days,
                                       'aging_threshold_days', aging_threshold_days,
                                       'aging_breached', aging_breached,
                                       'escalations_attached', to_jsonb(escalations_attached),
                                       'row_kind', row_kind)
                                     order by user_id, rank)
                                from d), '[]'::jsonb))
$$;

-- posture: unchanged grants re-asserted
revoke all on public.vw_jason_decision_digest from public, anon;
grant select on public.vw_jason_decision_digest to authenticated, service_role;
revoke all on function public.jason_decision_digest() from public, anon;
grant execute on function public.jason_decision_digest() to authenticated, service_role;
revoke all on function public.escalation_subject_codes(jsonb) from public, anon;
grant execute on function public.escalation_subject_codes(jsonb) to authenticated, service_role;

do $assert$
declare n int;
begin
  if public.escalation_subject_codes('{"escalates":" sb-7 ","related":"SB-8"}') <> array['SB-7','SB-8']
     or public.escalation_subject_codes('{"related":["SB-9","x"],"escalates":{"a":1}}') <> array['SB-9'] then
    raise exception 'SB-607 part 3: subject codes do not read escalates/related';
  end if;
  select count(*) into n from public.vw_jason_decision_digest d
    join public.work_items w on w.ticket_code = d.ticket_code and w.user_id = d.user_id
   where d.row_kind = 'item' and w.title ~* '^\s*ESCALATION'
     and (w.meta->>'blocker_class' = 'human_decision' or coalesce(w.authority_level, 0) >= 3);
  if n <> 0 then raise exception 'SB-607 part 3: % folded escalations listed as items', n; end if;
  select count(*) into n from public.work_items e
   where e.ticket_code in ('SB-520','SB-549','SB-553','39P-027') and e.status not in ('done','cancelled') and not e.archived
     and (select count(*) from public.vw_jason_decision_digest d where d.ticket_code = e.ticket_code)
       + (select count(*) from public.vw_jason_decision_digest d where e.ticket_code = any(d.escalations_attached)) <> 1;
  if n <> 0 then raise exception 'SB-607 part 3: % live escalations not listed exactly once', n; end if;
  if has_table_privilege('anon', 'public.vw_jason_decision_digest', 'select')
     or not exists (select 1 from pg_class where oid = 'public.vw_jason_decision_digest'::regclass
                      and reloptions @> array['security_invoker=true']) then
    raise exception 'SB-607 part 3: digest view posture';
  end if;
end
$assert$;
