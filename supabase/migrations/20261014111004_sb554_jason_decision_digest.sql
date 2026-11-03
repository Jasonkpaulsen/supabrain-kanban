-- SB-554 (ADR-FLOW-005 D6-D7; work package pkg-2). Jason-blocker class and one decision digest.
-- 4 of 19 awaiting_jason items were escalations of items already waiting on Jason. This
-- migration is additive: it creates new objects only and rewrites no ticket.
--   * escalation_gate_mode(gate): the enforcement switch for SB-554 and SB-526. Returns 'warn'
--     until Jason approves the ticket; flipping to 'enforce' is one CREATE OR REPLACE.
--   * escalation_subject_codes(meta): the ticket codes an escalation is about.
--   * jason_blocker_class(codes): human_decision / agent / unresolved.
--   * trg_escalation_blocker_class (BEFORE INSERT): stamps meta.blocker_class, digest_routed
--     and classified_by on ESCALATION rows. Fails open; in warn mode it never blocks an insert.
--   * vw_jason_decision_digest + jason_decision_digest(): each open item waiting on Jason once,
--     with aging thresholds and the no-op escalations folded into escalations_attached.
-- Items waiting on an outside party (meta.awaiting_external, ADR D1) are not Jason decisions.

create or replace function public.escalation_gate_mode(p_gate text)
returns text
language sql stable
set search_path = public
as $fn$
  select 'warn'::text
$fn$;

comment on function public.escalation_gate_mode(text) is
  'SB-554 / SB-526 enforcement switch. Returns warn until Jason approves the ticket; flipping to enforce is one CREATE OR REPLACE in a migration (ADR-FLOW-005 section 6).';

create or replace function public.escalation_subject_codes(p_meta jsonb)
returns text[]
language sql immutable
set search_path = public
as $fn$
  select coalesce(array_agg(distinct c order by c), '{}'::text[])
    from (
      select upper(btrim(v)) as c
        from (
          select p_meta->>'blocker_ref' as v
          union all
          select p_meta->>'upstream_ticket'
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
$fn$;

comment on function public.escalation_subject_codes(jsonb) is
  'SB-554: distinct upper-trimmed ticket codes an escalation names (blocker_ref, upstream_ticket, related_tickets[], requires_jason[]).';

create or replace function public.jason_blocker_class(p_codes text[])
returns text
language sql stable security invoker
set search_path = public
as $fn$
  with subj as (
    select w.id, w.status, w.approval_status, w.authority_level, w.meta
      from public.work_items w
     where w.ticket_code = any(p_codes)
       and w.status not in ('done', 'cancelled')
       and not w.archived
  ),
  human as (
    select s.id
      from subj s
     where not (nullif(btrim(s.meta->>'awaiting_external'), '') is not null
                and lower(btrim(s.meta->>'awaiting_external')) <> 'false')
       and (
             s.status = 'awaiting_jason'
          or (s.approval_status = 'pending' and (coalesce(s.authority_level, 1) >= 2 or s.meta ? 'proposal_type'))
          or (case jsonb_typeof(s.meta->'requires_jason')
                when 'boolean' then s.meta->'requires_jason' = 'true'::jsonb
                when 'string'  then lower(btrim(s.meta->>'requires_jason')) = 'true'
                when 'array'   then jsonb_array_length(s.meta->'requires_jason') > 0
                else false end)
          or (case jsonb_typeof(s.meta->'needs_jason')
                when 'boolean' then s.meta->'needs_jason' = 'true'::jsonb
                when 'string'  then lower(btrim(s.meta->>'needs_jason')) = 'true'
                when 'array'   then jsonb_array_length(s.meta->'needs_jason') > 0
                else false end)
          or exists (
               select 1
                 from public.work_item_links l
                 join public.work_items x
                   on x.id = case when l.link_type = 'blocks' then l.from_item_id else l.to_item_id end
                where ((l.link_type = 'blocks' and l.to_item_id = s.id)
                    or (l.link_type = 'blocked_by' and l.from_item_id = s.id))
                  and x.status not in ('done', 'cancelled')
                  and not x.archived
                  and not (nullif(btrim(x.meta->>'awaiting_external'), '') is not null
                           and lower(btrim(x.meta->>'awaiting_external')) <> 'false')
                  and (
                        x.status = 'awaiting_jason'
                     or (x.approval_status = 'pending' and (coalesce(x.authority_level, 1) >= 2 or x.meta ? 'proposal_type'))
                     or (case jsonb_typeof(x.meta->'requires_jason')
                           when 'boolean' then x.meta->'requires_jason' = 'true'::jsonb
                           when 'string'  then lower(btrim(x.meta->>'requires_jason')) = 'true'
                           when 'array'   then jsonb_array_length(x.meta->'requires_jason') > 0
                           else false end)
                     or (case jsonb_typeof(x.meta->'needs_jason')
                           when 'boolean' then x.meta->'needs_jason' = 'true'::jsonb
                           when 'string'  then lower(btrim(x.meta->>'needs_jason')) = 'true'
                           when 'array'   then jsonb_array_length(x.meta->'needs_jason') > 0
                           else false end)
                  )
             )
       )
  )
  select case
           when not exists (select 1 from subj) then 'unresolved'
           when exists (select 1 from human) then 'human_decision'
           else 'agent'
         end
$fn$;

comment on function public.jason_blocker_class(text[]) is
  'SB-554 (ADR-FLOW-005 D6): human_decision when a subject (or an item blocking it, one hop) waits on Jason; agent when the subjects resolve but none does; unresolved when no open subject exists. Outside-party waits are not Jason decisions.';

create or replace function public.classify_escalation_on_insert()
returns trigger
language plpgsql
set search_path = public
as $fn$
declare
  v_class text;
begin
  if NEW.title is null or NEW.title not ilike 'ESCALATION%' then
    return NEW;
  end if;
  begin
    v_class := case
                 when coalesce(NEW.authority_level, 0) >= 3
                   or NEW.status = 'awaiting_jason'
                   or NEW.meta->>'flagged_for_jason' = 'true'
                 then 'human_decision'
                 else public.jason_blocker_class(public.escalation_subject_codes(NEW.meta))
               end;
    NEW.meta := coalesce(NEW.meta, '{}'::jsonb)
                || jsonb_build_object('blocker_class', v_class,
                                      'digest_routed', v_class = 'human_decision',
                                      'classified_by', 'SB-554');
  exception when others then
    return NEW;
  end;
  if v_class = 'human_decision' and public.escalation_gate_mode('SB-554') = 'enforce' then
    raise exception 'ESCALATION-003: route to the decision digest; the subject waits on Jason'
      using errcode = 'P0554', hint = 'select * from public.vw_jason_decision_digest';
  end if;
  return NEW;
end
$fn$;

comment on function public.classify_escalation_on_insert() is
  'SB-554: BEFORE INSERT on work_items. Stamps meta.blocker_class, digest_routed, classified_by on ESCALATION rows; fails open. Raises P0554 only when escalation_gate_mode(SB-554) = enforce.';

do $$
begin
  if not exists (select 1 from pg_trigger
                  where tgname = 'trg_escalation_blocker_class'
                    and tgrelid = 'public.work_items'::regclass) then
    create trigger trg_escalation_blocker_class
      before insert on public.work_items
      for each row execute function public.classify_escalation_on_insert();
  end if;
end $$;

create or replace view public.vw_jason_decision_digest
with (security_invoker = true) as
with esc as (
  select e.id, e.user_id, e.ticket_code, e.authority_level,
         coalesce(e.meta->>'blocker_class',
                  case
                    when coalesce(e.authority_level, 0) >= 3
                      or e.status = 'awaiting_jason'
                      or e.meta->>'flagged_for_jason' = 'true'
                    then 'human_decision'
                    else public.jason_blocker_class(public.escalation_subject_codes(e.meta))
                  end) as blocker_class,
         public.escalation_subject_codes(e.meta) as subjects
    from public.work_items e
   where e.title ilike 'ESCALATION%'
     and e.status not in ('done', 'cancelled')
     and not e.archived
),
folded as (
  select esc.id, esc.user_id, esc.ticket_code, esc.subjects
    from esc
   where esc.blocker_class = 'human_decision' or coalesce(esc.authority_level, 0) >= 3
),
base as (
  select w.id, w.ticket_code, w.project_id, w.user_id, w.priority, w.status, w.authority_level,
         w.approval_status, w.title, w.meta,
         round((extract(epoch from now() - w.updated_at) / 86400)::numeric, 1) as waiting_days,
         case w.priority when 'critical' then 3 when 'high' then 7 when 'medium' then 14 when 'low' then 30 else 14 end
           as aging_threshold_days,
         case w.priority when 'critical' then 1 when 'high' then 2 when 'medium' then 3 when 'low' then 4 else 5 end
           as priority_rank
    from public.work_items w
   where w.status not in ('done', 'cancelled')
     and not w.archived
     and (w.status = 'awaiting_jason'
          or (w.approval_status = 'pending' and (coalesce(w.authority_level, 1) >= 2 or w.meta ? 'proposal_type')))
     and not (nullif(btrim(w.meta->>'awaiting_external'), '') is not null
              and lower(btrim(w.meta->>'awaiting_external')) <> 'false')
     and not exists (select 1 from folded f where f.id = w.id)
)
select b.ticket_code,
       b.project_id,
       b.user_id,
       b.priority,
       b.status,
       b.authority_level,
       b.approval_status,
       b.title,
       left(coalesce(b.meta->>'decision_needed', b.meta->>'blocked_on', b.meta->>'approval_note'), 200) as decision_needed,
       b.waiting_days,
       b.aging_threshold_days,
       b.waiting_days > b.aging_threshold_days as aging_breached,
       coalesce((select array_agg(f.ticket_code order by f.ticket_code)
                   from folded f
                  where f.user_id = b.user_id and f.subjects @> array[b.ticket_code]), '{}'::text[]) as escalations_attached,
       row_number() over (partition by b.user_id
                          order by b.priority_rank, b.waiting_days desc, b.ticket_code) as rank
  from base b;

comment on view public.vw_jason_decision_digest is
  'SB-554 (ADR-FLOW-005 D7): one row per open item waiting on Jason (awaiting_jason, or a pending L2+ / proposal approval). ESCALATION rows of class human_decision or L3+ are folded into escalations_attached of their subject. Aging thresholds critical 3 / high 7 / medium 14 / low 30 days, measured from updated_at.';

revoke all on public.vw_jason_decision_digest from anon;

create or replace function public.jason_decision_digest()
returns jsonb
language sql stable security invoker
set search_path = public
as $fn$
  with d as (
    select * from public.vw_jason_decision_digest
     where auth.uid() is null or user_id = auth.uid()
  ),
  noop as (
    select count(*) as n
      from public.work_items e
     where e.title ilike 'ESCALATION%'
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
           'items', coalesce((select jsonb_agg(jsonb_build_object(
                                       'rank', rank, 'ticket_code', ticket_code, 'priority', priority,
                                       'status', status, 'authority_level', authority_level,
                                       'approval_status', approval_status, 'title', title,
                                       'decision_needed', decision_needed, 'waiting_days', waiting_days,
                                       'aging_threshold_days', aging_threshold_days,
                                       'aging_breached', aging_breached,
                                       'escalations_attached', to_jsonb(escalations_attached))
                                     order by user_id, rank)
                                from d), '[]'::jsonb))
$fn$;

comment on function public.jason_decision_digest() is
  'SB-554 (ADR-FLOW-005 D7): the decision digest as jsonb {total, by_priority, breached, oldest_days, noop_escalations, items}. Filters to auth.uid() when called with a user session.';

revoke execute on function public.jason_decision_digest() from public, anon;
grant execute on function public.jason_decision_digest() to authenticated, service_role;

do $$
declare
  v_att text[];
begin
  if to_regprocedure('public.escalation_gate_mode(text)') is null
     or to_regprocedure('public.escalation_subject_codes(jsonb)') is null
     or to_regprocedure('public.jason_blocker_class(text[])') is null
     or to_regprocedure('public.classify_escalation_on_insert()') is null
     or to_regprocedure('public.jason_decision_digest()') is null
     or to_regclass('public.vw_jason_decision_digest') is null then
    raise exception 'SB-554: an object is missing';
  end if;
  if not exists (select 1 from pg_trigger
                  where tgname = 'trg_escalation_blocker_class'
                    and tgrelid = 'public.work_items'::regclass and tgenabled = 'O') then
    raise exception 'SB-554: trg_escalation_blocker_class missing or not enabled';
  end if;
  if not exists (select 1 from pg_class
                  where oid = 'public.vw_jason_decision_digest'::regclass
                    and reloptions @> array['security_invoker=true']) then
    raise exception 'SB-554: vw_jason_decision_digest is not security_invoker';
  end if;
  if public.escalation_gate_mode('SB-554') <> 'warn' or public.escalation_gate_mode('SB-526') <> 'warn' then
    raise exception 'SB-554: escalation_gate_mode must return warn until Jason approves';
  end if;
  if has_function_privilege('anon', 'public.jason_decision_digest()', 'execute')
     or not has_function_privilege('authenticated', 'public.jason_decision_digest()', 'execute') then
    raise exception 'SB-554: jason_decision_digest grants are wrong';
  end if;
  if exists (select 1 from public.work_items where ticket_code = 'SB-413' and status = 'awaiting_jason' and not archived) then
    select escalations_attached into v_att from public.vw_jason_decision_digest where ticket_code = 'SB-413';
    if v_att is null or not ('SB-520' = any(v_att)) then
      raise exception 'SB-554: SB-413 digest row does not carry SB-520 in escalations_attached';
    end if;
  end if;
  if exists (select 1 from public.vw_jason_decision_digest
              where ticket_code in ('SB-520', 'SB-549', 'SB-553', '39P-027')) then
    raise exception 'SB-554: a folded escalation is listed as its own digest row';
  end if;
  if (select count(*) from public.vw_jason_decision_digest)
     <> (select count(distinct ticket_code) from public.vw_jason_decision_digest) then
    raise exception 'SB-554: the digest lists an item more than once';
  end if;
end $$;