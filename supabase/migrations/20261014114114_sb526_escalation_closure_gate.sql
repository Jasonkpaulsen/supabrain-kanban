-- SB-526 (ADR-FLOW-005 D8; work package pkg-2). Escalation closure follows the upstream.
-- 6 of 12 done escalations had an upstream still not finished; 4 were closed as done with
-- exempt flags. This migration is additive: new objects only, no ticket is rewritten.
--   * escalation_upstream_id(title, meta, user, self): the escalated ticket (meta.upstream_ticket,
--     then meta.escalates, then the first ticket code in the title), same owner, never itself.
--   * escalation_open_blockers(item): sorted codes of open items that block it.
--   * trg_escalation_closure (BEFORE INSERT OR UPDATE OF status): stamps meta.escalation_snapshot
--     on insert; on a close into done while the upstream is stuck, the verdict is
--     ESCALATION-002 (nothing changed since the snapshot) or ESCALATION-001 (no re-verification
--     evidence). No *_exempt flag is read; the escape hatch is cancel_work_item(..., 'duplicate').
--     escalation_gate_mode('SB-526') returns 'warn' until Jason approves SB-526: the close
--     succeeds, meta.escalation_closure records the verdict and a WARNING is raised.
--   * vw_escalation_closure_audit: ok / held / violation per escalation (row_kind 'escalation')
--     plus one governance_violation row per upstream blocked > 14 days with a done escalation
--     in its history (row_kind 'upstream'), as a UNION ALL.
-- handoff* issue types and unresolvable upstreams are out of scope.

create or replace function public.escalation_upstream_id(p_title text, p_meta jsonb, p_user_id uuid, p_self uuid)
returns uuid
language plpgsql stable security definer
set search_path = public
as $fn$
declare
  v_code text;
  v_id   uuid;
begin
  v_code := upper(btrim(p_meta->>'upstream_ticket'));
  if v_code ~ '^[A-Z0-9]+-[0-9]+$' then
    select w.id into v_id from public.work_items w
     where w.ticket_code = v_code and w.user_id = p_user_id and w.id is distinct from p_self
     limit 1;
    if v_id is not null then return v_id; end if;
  end if;
  v_code := upper(btrim(p_meta->>'escalates'));
  if v_code ~ '^[A-Z0-9]+-[0-9]+$' then
    select w.id into v_id from public.work_items w
     where w.ticket_code = v_code and w.user_id = p_user_id and w.id is distinct from p_self
     limit 1;
    if v_id is not null then return v_id; end if;
  end if;
  v_code := substring(p_title from '[A-Z0-9]+-[0-9]+');
  if v_code is not null then
    select w.id into v_id from public.work_items w
     where w.ticket_code = v_code and w.user_id = p_user_id and w.id is distinct from p_self
     limit 1;
    if v_id is not null then return v_id; end if;
  end if;
  return null;
end
$fn$;

comment on function public.escalation_upstream_id(text, jsonb, uuid, uuid) is
  'SB-526 (ADR-FLOW-005 D8): the work item an escalation escalates: meta.upstream_ticket, then meta.escalates, then the first ticket code in the title; same user_id, never the escalation itself; null when none resolves.';

revoke execute on function public.escalation_upstream_id(text, jsonb, uuid, uuid) from public, anon;
grant execute on function public.escalation_upstream_id(text, jsonb, uuid, uuid) to authenticated, service_role;

create or replace function public.escalation_open_blockers(p_item_id uuid)
returns text[]
language sql stable
set search_path = public
as $fn$
  select coalesce(array_agg(x.ticket_code order by x.ticket_code), '{}'::text[])
    from public.work_items x
   where x.status not in ('done', 'cancelled')
     and exists (select 1 from public.work_item_links l
                  where (l.link_type = 'blocks' and l.from_item_id = x.id and l.to_item_id = p_item_id)
                     or (l.link_type = 'blocked_by' and l.from_item_id = p_item_id and l.to_item_id = x.id))
$fn$;

comment on function public.escalation_open_blockers(uuid) is
  'SB-526: sorted ticket codes of open (not done/cancelled) items that block the given item (X blocks item, or item blocked_by X).';

create or replace function public.enforce_escalation_closure()
returns trigger
language plpgsql
set search_path = public
as $fn$
declare
  v_up       uuid;
  v_code     text;
  v_status   text;
  v_assignee text;
  v_blockers text[];
  v_snap     jsonb;
  n_open     int;
  n_unowned  int;
  n_self     int;
  n_comments int;
  v_verdict  text;
  v_msg      text;
begin
  if not (coalesce(NEW.title, '') ~* '^\s*ESCALATION\M'
          or NEW.meta->>'issue_type' in ('stale_critical_blocker', 'stalled_design_blocker', 'critical_path_blocker',
                                         'stale_critical_review', 'review_block')) then
    return NEW;
  end if;
  if coalesce(NEW.meta->>'issue_type', '') ~ '^handoff' then
    return NEW;
  end if;
  if TG_OP = 'UPDATE' and not (NEW.status = 'done' and OLD.status is distinct from 'done') then
    return NEW;
  end if;

  begin
    v_up := public.escalation_upstream_id(NEW.title, NEW.meta, NEW.user_id, NEW.id);
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
    else
      v_snap := OLD.meta->'escalation_snapshot';
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
     where c.work_item_id = v_up and c.created_at > NEW.created_at;

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
$fn$;

comment on function public.enforce_escalation_closure() is
  'SB-526 (ADR-FLOW-005 D8): BEFORE INSERT OR UPDATE OF status on work_items. Stamps meta.escalation_snapshot on insert; on a close into done while the upstream is stuck sets verdict ESCALATION-002 or ESCALATION-001. warn mode stamps meta.escalation_closure and raises a WARNING; enforce mode raises P0001. No *_exempt flag is read.';

do $$
begin
  if not exists (select 1 from pg_trigger
                  where tgname = 'trg_escalation_closure'
                    and tgrelid = 'public.work_items'::regclass) then
    create trigger trg_escalation_closure
      before insert or update of status on public.work_items
      for each row execute function public.enforce_escalation_closure();
  end if;
end $$;

create or replace view public.vw_escalation_closure_audit
with (security_invoker = true) as
with esc as (
  select e.id, e.user_id, e.ticket_code, e.status, e.created_at,
         e.meta->'escalation_snapshot' as snap,
         public.escalation_upstream_id(e.title, e.meta, e.user_id, e.id) as up_id
    from public.work_items e
   where (e.title ~* '^\s*ESCALATION\M'
          or e.meta->>'issue_type' in ('stale_critical_blocker', 'stalled_design_blocker', 'critical_path_blocker',
                                       'stale_critical_review', 'review_block'))
     and coalesce(e.meta->>'issue_type', '') !~ '^handoff'
     and e.status <> 'cancelled'
),
ev as (
  select esc.*, u.ticket_code as upstream_code, u.status as upstream_status, u.assignee as upstream_assignee,
         u.updated_at as upstream_updated_at, u.user_id as upstream_user_id,
         public.escalation_open_blockers(u.id) as blockers,
         b.open_blockers, b.unowned_blockers, b.self_blockers, c.comments_after
    from esc
    join public.work_items u on u.id = esc.up_id
    cross join lateral (
      select count(*) as open_blockers,
             count(*) filter (where nullif(btrim(x.assignee), '') is null) as unowned_blockers,
             count(*) filter (where x.id = esc.id) as self_blockers
        from public.work_items x
       where x.status not in ('done', 'cancelled')
         and exists (select 1 from public.work_item_links l
                      where (l.link_type = 'blocks' and l.from_item_id = x.id and l.to_item_id = u.id)
                         or (l.link_type = 'blocked_by' and l.from_item_id = u.id and l.to_item_id = x.id))
    ) b
    cross join lateral (
      select count(*) as comments_after
        from public.work_item_comments cm
       where cm.work_item_id = u.id and cm.created_at > esc.created_at
    ) c
),
judged as (
  select ev.*,
         (ev.upstream_status not in ('done', 'cancelled')
          and (ev.upstream_status in ('blocked', 'on_hold', 'awaiting_jason', 'escalated')
               or ev.upstream_status = ev.snap->>'status')) as stuck,
         (ev.snap is not null
          and ev.upstream_status = ev.snap->>'status'
          and ev.upstream_assignee is not distinct from ev.snap->>'assignee'
          and to_jsonb(ev.blockers) = ev.snap->'blockers') as same_as_snapshot,
         (ev.comments_after >= 1 and nullif(btrim(ev.upstream_assignee), '') is not null
          and ev.open_blockers >= 1 and ev.unowned_blockers = 0 and ev.self_blockers = 0) as has_evidence
    from ev
)
select j.ticket_code,
       j.status,
       j.upstream_code,
       j.upstream_status,
       j.open_blockers,
       j.unowned_blockers,
       j.comments_after,
       j.snap is not null as has_snapshot,
       case
         when j.stuck and (j.same_as_snapshot or not j.has_evidence) and j.status = 'done' then 'violation'
         when j.stuck and (j.same_as_snapshot or not j.has_evidence) then 'held'
         else 'ok'
       end as verdict,
       'escalation'::text as row_kind,
       j.user_id,
       null::bigint as done_escalations
  from judged j
union all
select u.ticket_code,
       u.status,
       u.ticket_code as upstream_code,
       u.status as upstream_status,
       g.open_blockers,
       g.unowned_blockers,
       null::bigint as comments_after,
       null::boolean as has_snapshot,
       'governance_violation'::text as verdict,
       'upstream'::text as row_kind,
       u.user_id,
       g.done_escalations
  from (select ev.up_id,
               max(ev.open_blockers) as open_blockers,
               max(ev.unowned_blockers) as unowned_blockers,
               count(*) filter (where ev.status = 'done') as done_escalations
          from ev
         group by ev.up_id) g
  join public.work_items u on u.id = g.up_id
 where g.done_escalations > 0
   and u.status = 'blocked'
   and u.updated_at < now() - interval '14 days';

comment on view public.vw_escalation_closure_audit is
  'SB-526 (ADR-FLOW-005 D8): row_kind escalation = one row per escalation (not cancelled, handoff* excluded, upstream resolved) with verdict ok / held (open, a close now would be held) / violation (done while the upstream is stuck without evidence or unchanged since the snapshot). row_kind upstream = governance_violation for an upstream blocked > 14 days (by updated_at) with a done escalation in its history.';

revoke all on public.vw_escalation_closure_audit from anon;

do $$
begin
  if to_regprocedure('public.escalation_upstream_id(text,jsonb,uuid,uuid)') is null
     or to_regprocedure('public.escalation_open_blockers(uuid)') is null
     or to_regprocedure('public.enforce_escalation_closure()') is null
     or to_regclass('public.vw_escalation_closure_audit') is null then
    raise exception 'SB-526: an object is missing';
  end if;
  if not exists (select 1 from pg_trigger
                  where tgname = 'trg_escalation_closure'
                    and tgrelid = 'public.work_items'::regclass and tgenabled = 'O') then
    raise exception 'SB-526: trg_escalation_closure missing or not enabled';
  end if;
  if not ('trg_done_gate' collate "C" < 'trg_escalation_closure' collate "C"
          and 'trg_escalation_closure' collate "C" < 'trg_qa_gate' collate "C")
     or (select count(*) from pg_trigger where tgrelid = 'public.work_items'::regclass
          and tgname in ('trg_done_gate', 'trg_qa_gate')) <> 2 then
    raise exception 'SB-526: trigger order is not trg_done_gate < trg_escalation_closure < trg_qa_gate';
  end if;
  if not exists (select 1 from pg_class
                  where oid = 'public.vw_escalation_closure_audit'::regclass
                    and reloptions @> array['security_invoker=true']) then
    raise exception 'SB-526: vw_escalation_closure_audit is not security_invoker';
  end if;
  if public.escalation_gate_mode('SB-526') <> 'warn' then
    raise exception 'SB-526: escalation_gate_mode must return warn until Jason approves';
  end if;
  if has_function_privilege('anon', 'public.escalation_upstream_id(text,jsonb,uuid,uuid)', 'execute') then
    raise exception 'SB-526: escalation_upstream_id is executable by anon';
  end if;
  if not exists (select 1 from public.vw_escalation_closure_audit
                  where ticket_code = 'SB-525' and row_kind = 'escalation' and verdict = 'ok') then
    raise exception 'SB-526: SB-525 is not ok in the audit view';
  end if;
  if not exists (select 1 from public.vw_escalation_closure_audit
                  where ticket_code = 'SB-426' and row_kind = 'escalation' and verdict = 'violation') then
    raise exception 'SB-526: SB-426 is not a violation in the audit view';
  end if;
end $$;