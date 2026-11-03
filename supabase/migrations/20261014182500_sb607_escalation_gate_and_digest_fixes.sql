-- SB-607 (ADR-FLOW-005 D6-D8; the two majors from the pkg-2 independent verifier, 2026-10-14).
--
-- 1. Closure-gate bypass (SB-526). On UPDATE, enforce_escalation_closure() judged scope and
--    upstream from NEW, and its trigger fires only on UPDATE OF status. So a title or meta edit,
--    in the same statement or in a meta-only update beforehand, could take an escalation out of
--    scope, point it at another upstream, or rewrite the stored snapshot it is compared against.
--    Now:
--    a. trg_escalation_snapshot_guard keeps meta.escalation_snapshot exactly as the database
--       wrote it at INSERT; any later update that changes or removes it gets it back. Other meta
--       changes in the same update are kept.
--    b. On UPDATE the gate judges the STORED row (OLD). A row with a stored snapshot is an
--       escalation for good, and its upstream is the one the snapshot names; title, issue_type
--       and upstream keys edited later no longer matter. Rows from before SB-526 (no snapshot)
--       are judged from OLD as before. The INSERT path is unchanged.
-- 2. Digest drops (SB-554). vw_jason_decision_digest folds human-decision escalations (L3+,
--    awaiting_jason, flagged, human_decision) under their subject, but listed them nowhere when
--    the subject was not itself a digest row: on 2026-10-14 SB-549 and 39P-027 were invisible.
--    Such an escalation is now its own digest row; attached ones stay attached, never doubled.

-- 1a ---------------------------------------------------------------------------------------------
create or replace function public.preserve_escalation_snapshot()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
begin
  if OLD.meta ? 'escalation_snapshot'
     and (NEW.meta is null or NEW.meta->'escalation_snapshot' is distinct from OLD.meta->'escalation_snapshot') then
    NEW.meta := coalesce(NEW.meta, '{}'::jsonb) || jsonb_build_object('escalation_snapshot', OLD.meta->'escalation_snapshot');
  end if;
  return NEW;
end
$function$;

comment on function public.preserve_escalation_snapshot() is
  'SB-607: meta.escalation_snapshot is written once, by the SB-526 insert path, and never changes after.';

create trigger trg_escalation_snapshot_guard
  before update of meta on public.work_items
  for each row execute function public.preserve_escalation_snapshot();

-- 1b ---------------------------------------------------------------------------------------------
create or replace function public.enforce_escalation_closure()
 returns trigger
 language plpgsql
 set search_path to 'public'
as $function$
declare
  v_up       uuid;
  v_code     text;
  v_status   text;
  v_assignee text;
  v_blockers text[];
  v_snap     jsonb;
  v_created  timestamptz;
  n_open     int;
  n_unowned  int;
  n_self     int;
  n_comments int;
  v_verdict  text;
  v_msg      text;
begin
  if TG_OP = 'UPDATE' and not (NEW.status = 'done' and OLD.status is distinct from 'done') then
    return NEW;
  end if;

  if TG_OP = 'UPDATE' then
    -- SB-607: judge the stored row. A stored snapshot makes it an escalation for good.
    v_snap := OLD.meta->'escalation_snapshot';
    if v_snap is null then
      if not (coalesce(OLD.title, '') ~* '^\s*ESCALATION\M'
              or OLD.meta->>'issue_type' in ('stale_critical_blocker', 'stalled_design_blocker', 'critical_path_blocker',
                                             'stale_critical_review', 'review_block')) then
        return NEW;
      end if;
      if coalesce(OLD.meta->>'issue_type', '') ~ '^handoff' then
        return NEW;
      end if;
    end if;
    v_created := OLD.created_at;
  else
    if not (coalesce(NEW.title, '') ~* '^\s*ESCALATION\M'
            or NEW.meta->>'issue_type' in ('stale_critical_blocker', 'stalled_design_blocker', 'critical_path_blocker',
                                           'stale_critical_review', 'review_block')) then
      return NEW;
    end if;
    if coalesce(NEW.meta->>'issue_type', '') ~ '^handoff' then
      return NEW;
    end if;
    v_created := NEW.created_at;
  end if;

  begin
    if TG_OP = 'UPDATE' and v_snap ? 'upstream' then
      v_up := public.escalation_upstream_id(null, jsonb_build_object('upstream_ticket', v_snap->>'upstream'), OLD.user_id, OLD.id);
    elsif TG_OP = 'UPDATE' then
      v_up := public.escalation_upstream_id(OLD.title, OLD.meta, OLD.user_id, OLD.id);
    else
      v_up := public.escalation_upstream_id(NEW.title, NEW.meta, NEW.user_id, NEW.id);
    end if;
    if v_up is null then
      return NEW;
    end if;
    select w.ticket_code, w.status, w.assignee into v_code, v_status, v_assignee
      from public.work_items w where w.id = v_up;
    v_blockers := public.escalation_open_blockers(v_up);

    if TG_OP = 'INSERT' then
      v_snap := null;  -- a snapshot supplied by the caller is never trusted
      NEW.meta := coalesce(NEW.meta, '{}'::jsonb) || jsonb_build_object('escalation_snapshot',
                    jsonb_build_object('upstream', v_code, 'status', v_status, 'assignee', v_assignee,
                                       'blockers', to_jsonb(v_blockers), 'at', now()));
    end if;

    if NEW.status is distinct from 'done' then
      return NEW;
    end if;
    if v_status in ('done', 'cancelled')
       or not (v_status in ('blocked', 'on_hold', 'awaiting_jason', 'escalated')
               or v_status = v_snap->>'status') then
      return NEW;
    end if;

    select count(*),
           count(*) filter (where nullif(btrim(x.assignee), '') is null),
           count(*) filter (where x.id = NEW.id)
      into n_open, n_unowned, n_self
      from public.work_items x
     where x.status not in ('done', 'cancelled')
       and exists (select 1 from public.work_item_links l
                    where (l.link_type = 'blocks' and l.from_item_id = x.id and l.to_item_id = v_up)
                       or (l.link_type = 'blocked_by' and l.from_item_id = v_up and l.to_item_id = x.id));
    select count(*) into n_comments
      from public.work_item_comments c
     where c.work_item_id = v_up and c.created_at > v_created;

    if v_snap is not null
       and v_status = v_snap->>'status'
       and v_assignee is not distinct from v_snap->>'assignee'
       and to_jsonb(v_blockers) = v_snap->'blockers' then
      v_verdict := 'ESCALATION-002';
    elsif not (n_comments >= 1 and nullif(btrim(v_assignee), '') is not null
               and n_open >= 1 and n_unowned = 0 and n_self = 0) then
      v_verdict := 'ESCALATION-001';
    else
      return NEW;
    end if;

    v_msg := format('%s: escalation %s cannot close while upstream %s is %s (open blockers %s, unowned %s, comments since escalation %s)',
                    v_verdict, coalesce(NEW.ticket_code, 'new row'), v_code, v_status, n_open, n_unowned, n_comments);
  exception when others then
    return NEW;
  end;

  if public.escalation_gate_mode('SB-526') = 'enforce' then
    raise exception '%', v_msg
      using errcode = 'P0001',
            hint = 'Re-verify the upstream (comment, owner, owned blockers) or close with cancel_work_item(..., ''duplicate'', ...). See public.vw_escalation_closure_audit.';
  end if;
  NEW.meta := coalesce(NEW.meta, '{}'::jsonb) || jsonb_build_object('escalation_closure',
                jsonb_build_object('verdict', v_verdict, 'upstream', v_code, 'at', now()));
  raise warning '%', v_msg;
  return NEW;
end
$function$;

-- 2 ----------------------------------------------------------------------------------------------
create or replace view public.vw_jason_decision_digest with (security_invoker = true) as
with esc as (
  select e.id, e.user_id, e.ticket_code, e.authority_level,
         coalesce(e.meta->>'blocker_class',
                  case when coalesce(e.authority_level, 0) >= 3 or e.status = 'awaiting_jason' or e.meta->>'flagged_for_jason' = 'true'
                       then 'human_decision'
                       else public.jason_blocker_class(public.escalation_subject_codes(e.meta)) end) as blocker_class,
         public.escalation_subject_codes(e.meta) as subjects
    from public.work_items e
   where e.title ilike 'ESCALATION%' and e.status <> all (array['done', 'cancelled']) and not e.archived
), folded as (
  select esc.id, esc.user_id, esc.ticket_code, esc.subjects
    from esc
   where esc.blocker_class = 'human_decision' or coalesce(esc.authority_level, 0) >= 3
), core as (
  select w.id, w.ticket_code, w.project_id, w.user_id, w.priority, w.status, w.authority_level,
         w.approval_status, w.title, w.meta, w.updated_at
    from public.work_items w
   where w.status <> all (array['done', 'cancelled']) and not w.archived
     and (w.status = 'awaiting_jason'
          or (w.approval_status = 'pending' and (coalesce(w.authority_level, 1) >= 2 or w.meta ? 'proposal_type')))
     and not (nullif(btrim(w.meta->>'awaiting_external'), '') is not null
              and lower(btrim(w.meta->>'awaiting_external')) <> 'false')
     and not exists (select 1 from folded f where f.id = w.id)
), orphan as (
  -- SB-607: a folded escalation whose subject is not a digest row is listed itself.
  select w.id, w.ticket_code, w.project_id, w.user_id, w.priority, w.status, w.authority_level,
         w.approval_status, w.title, w.meta, w.updated_at
    from public.work_items w
    join folded f on f.id = w.id
   where not exists (select 1 from core c where c.user_id = f.user_id and c.ticket_code = any (f.subjects))
), base as (
  select x.id, x.ticket_code, x.project_id, x.user_id, x.priority, x.status, x.authority_level,
         x.approval_status, x.title, x.meta,
         round(extract(epoch from now() - x.updated_at) / 86400::numeric, 1) as waiting_days,
         case x.priority when 'critical' then 3 when 'high' then 7 when 'medium' then 14 when 'low' then 30 else 14 end
           as aging_threshold_days,
         case x.priority when 'critical' then 1 when 'high' then 2 when 'medium' then 3 when 'low' then 4 else 5 end
           as priority_rank
    from (select * from core union all select * from orphan) x
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
       b.waiting_days > b.aging_threshold_days::numeric as aging_breached,
       coalesce((select array_agg(f.ticket_code order by f.ticket_code)
                   from folded f
                  where f.user_id = b.user_id and f.subjects @> array[b.ticket_code]), '{}'::text[]) as escalations_attached,
       row_number() over (partition by b.user_id order by b.priority_rank, b.waiting_days desc, b.ticket_code) as rank
  from base b;

-- assertions -------------------------------------------------------------------------------------
do $assert$
declare
  n int; m int;
begin
  if not exists (select 1 from pg_trigger where tgname = 'trg_escalation_snapshot_guard' and tgenabled = 'O'
                  and tgrelid = 'public.work_items'::regclass) then
    raise exception 'SB-607: trg_escalation_snapshot_guard missing or disabled';
  end if;
  if position('SB-607: judge the stored row' in pg_get_functiondef('public.enforce_escalation_closure()'::regprocedure)) = 0 then
    raise exception 'SB-607: enforce_escalation_closure not replaced';
  end if;
  if (select coalesce(reloptions::text, '') from pg_class where oid = 'public.vw_jason_decision_digest'::regclass)
     not like '%security_invoker=true%' then
    raise exception 'SB-607: digest view lost security_invoker';
  end if;
  if not has_table_privilege('authenticated', 'public.vw_jason_decision_digest', 'select') then
    raise exception 'SB-607: digest view lost its authenticated SELECT grant';
  end if;
  -- every folded escalation is visible, either as a row or attached to one
  with esc as (
    select e.id, e.user_id, e.ticket_code, e.authority_level,
           coalesce(e.meta->>'blocker_class',
                    case when coalesce(e.authority_level, 0) >= 3 or e.status = 'awaiting_jason' or e.meta->>'flagged_for_jason' = 'true'
                         then 'human_decision'
                         else public.jason_blocker_class(public.escalation_subject_codes(e.meta)) end) as blocker_class
      from public.work_items e
     where e.title ilike 'ESCALATION%' and e.status <> all (array['done', 'cancelled']) and not e.archived)
  select count(*) filter (where not exists (select 1 from public.vw_jason_decision_digest d
                                             where d.user_id = esc.user_id
                                               and (d.ticket_code = esc.ticket_code or esc.ticket_code = any (d.escalations_attached)))),
         count(*) filter (where exists (select 1 from public.vw_jason_decision_digest d
                                         where d.user_id = esc.user_id and d.ticket_code = esc.ticket_code)
                            and exists (select 1 from public.vw_jason_decision_digest d
                                         where d.user_id = esc.user_id and esc.ticket_code = any (d.escalations_attached)))
    into n, m
    from esc
   where esc.blocker_class = 'human_decision' or coalesce(esc.authority_level, 0) >= 3;
  if n <> 0 then raise exception 'SB-607: % human-decision escalations still missing from the digest', n; end if;
  if m <> 0 then raise exception 'SB-607: % escalations are both their own digest row and attached to another', m; end if;
end $assert$;
