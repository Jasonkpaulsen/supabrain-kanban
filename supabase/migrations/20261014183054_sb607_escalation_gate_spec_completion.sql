-- SB-607 part 2: complete the closure-gate hardening to the spec in
-- supabase/tests/escalation_closure_gate_suite.sql (TC-SB526-2, -7, -8, -8e), written by the
-- pkg-2 closer before its run was cut off. Part 1 (20261014182500) made the gate judge the stored
-- row and keep the snapshot; this completes it:
--   * escalation_upstream_id becomes SECURITY INVOKER (no cross-owner lookup through it) and is
--     no longer executable by anon;
--   * trg_escalation_closure also fires on title and meta updates;
--   * INSERT strips caller-supplied escalation_snapshot / escalation_closure from every row;
--   * UPDATE of an escalation that has no snapshot pins one from the stored row on its first write
--     (marked legacy), and a plain row that becomes an escalation is snapshotted in that update; a
--     snapshot taken in the same statement, or a legacy one, is never compared as "unchanged";
--   * meta.escalation_closure, once written, cannot be removed;
--   * vw_escalation_closure_audit recognises an escalation by its snapshot and judges it against
--     the snapshot's upstream.

-- helper ------------------------------------------------------------------------------------------
create or replace function public.escalation_in_scope(p_title text, p_meta jsonb)
returns boolean
language sql
immutable
set search_path to 'public'
as $function$
  -- coalesce matters: the SB-526 check "not (title_match or issue_type in (...))" was NULL for any
  -- row without an issue_type, so every such row was treated as an escalation and any ticket code in
  -- its title became an "upstream" (SB-605..607 were stamped that way).
  select (coalesce(p_title, '') ~* '^\s*ESCALATION\M'
          or coalesce(p_meta->>'issue_type', '') in ('stale_critical_blocker', 'stalled_design_blocker', 'critical_path_blocker',
                                                     'stale_critical_review', 'review_block'))
     and coalesce(p_meta->>'issue_type', '') !~ '^handoff'
$function$;

comment on function public.escalation_in_scope(text, jsonb) is
  'SB-526 / SB-607: a row is an escalation by its title or issue_type, never a handoff. A stored escalation_snapshot also makes it one.';

grant execute on function public.escalation_in_scope(text, jsonb) to authenticated, service_role;

-- upstream lookup under the caller's own permissions ------------------------------------------------
alter function public.escalation_upstream_id(text, jsonb, uuid, uuid) security invoker;
revoke all on function public.escalation_upstream_id(text, jsonb, uuid, uuid) from public, anon;
grant execute on function public.escalation_upstream_id(text, jsonb, uuid, uuid) to authenticated, service_role;

-- guard: snapshot unchanged, verdict never removed --------------------------------------------------
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
  if OLD.meta ? 'escalation_closure' and (NEW.meta is null or not NEW.meta ? 'escalation_closure') then
    NEW.meta := coalesce(NEW.meta, '{}'::jsonb) || jsonb_build_object('escalation_closure', OLD.meta->'escalation_closure');
  end if;
  return NEW;
end
$function$;

comment on function public.preserve_escalation_snapshot() is
  'SB-607: meta.escalation_snapshot is written only by trg_escalation_closure and never changes after; meta.escalation_closure is never removed.';

-- the gate --------------------------------------------------------------------------------------------
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
  v_snap     jsonb;     -- the snapshot the row is judged against
  v_cmp      jsonb;     -- the snapshot used for the "nothing changed" test; null when it was just taken or is legacy
  v_created  timestamptz;
  v_esc_old  boolean;
  n_open     int;
  n_unowned  int;
  n_self     int;
  n_comments int;
  v_verdict  text;
  v_msg      text;
begin
  if TG_OP = 'INSERT' then
    -- SB-607: trigger-owned keys are never caller-supplied
    if NEW.meta ? 'escalation_snapshot' or NEW.meta ? 'escalation_closure' then
      NEW.meta := NEW.meta - 'escalation_snapshot' - 'escalation_closure';
    end if;
    if not public.escalation_in_scope(NEW.title, NEW.meta) then
      return NEW;
    end if;
    v_created := NEW.created_at;
  else
    -- SB-607: judge the stored row. A stored snapshot makes it an escalation for good.
    v_snap := OLD.meta->'escalation_snapshot';
    v_esc_old := v_snap is not null or public.escalation_in_scope(OLD.title, OLD.meta);
    if not v_esc_old and not public.escalation_in_scope(NEW.title, NEW.meta) then
      return NEW;
    end if;
    v_created := OLD.created_at;
  end if;

  begin
    if v_snap is not null then
      v_up := public.escalation_upstream_id(null, jsonb_build_object('upstream_ticket', v_snap->>'upstream'), OLD.user_id, OLD.id);
    elsif TG_OP = 'UPDATE' and v_esc_old then
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

    if v_snap is null then
      -- INSERT, a legacy escalation's first write (marked legacy), or a row that just became one
      v_snap := jsonb_build_object('upstream', v_code, 'status', v_status, 'assignee', v_assignee,
                                   'blockers', to_jsonb(v_blockers), 'at', now())
                || case when TG_OP = 'UPDATE' and v_esc_old then '{"legacy": true}'::jsonb else '{}'::jsonb end;
      NEW.meta := coalesce(NEW.meta, '{}'::jsonb) || jsonb_build_object('escalation_snapshot', v_snap);
      v_cmp := null;
    elsif coalesce(v_snap->>'legacy', 'false') = 'true' then
      v_cmp := null;
    else
      v_cmp := v_snap;
    end if;

    if NEW.status is distinct from 'done' or (TG_OP = 'UPDATE' and OLD.status is not distinct from 'done') then
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

    if v_cmp is not null
       and v_status = v_cmp->>'status'
       and v_assignee is not distinct from v_cmp->>'assignee'
       and to_jsonb(v_blockers) = v_cmp->'blockers' then
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

create or replace trigger trg_escalation_closure
  before insert or update of status, title, meta on public.work_items
  for each row execute function public.enforce_escalation_closure();

-- audit view ------------------------------------------------------------------------------------------
create or replace view public.vw_escalation_closure_audit with (security_invoker = true) as
with esc as (
  select e.id, e.user_id, e.ticket_code, e.status, e.created_at,
         e.meta->'escalation_snapshot' as snap,
         case when e.meta->'escalation_snapshot' ? 'upstream'
              then public.escalation_upstream_id(null, jsonb_build_object('upstream_ticket', e.meta->'escalation_snapshot'->>'upstream'), e.user_id, e.id)
              else public.escalation_upstream_id(e.title, e.meta, e.user_id, e.id) end as up_id
    from public.work_items e
   where (e.meta ? 'escalation_snapshot' or public.escalation_in_scope(e.title, e.meta))
     and e.status <> 'cancelled'
), ev as (
  select esc.id, esc.user_id, esc.ticket_code, esc.status, esc.created_at, esc.snap, esc.up_id,
         u.ticket_code as upstream_code, u.status as upstream_status, u.assignee as upstream_assignee,
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
       where x.status <> all (array['done', 'cancelled'])
         and exists (select 1 from public.work_item_links l
                      where l.link_type = 'blocks' and l.from_item_id = x.id and l.to_item_id = u.id
                         or l.link_type = 'blocked_by' and l.from_item_id = u.id and l.to_item_id = x.id)) b
    cross join lateral (
      select count(*) as comments_after
        from public.work_item_comments cm
       where cm.work_item_id = u.id and cm.created_at > esc.created_at) c
), judged as (
  select ev.*,
         ev.upstream_status <> all (array['done', 'cancelled'])
           and (ev.upstream_status = any (array['blocked', 'on_hold', 'awaiting_jason', 'escalated'])
                or ev.upstream_status = ev.snap->>'status') as stuck,
         ev.snap is not null and coalesce(ev.snap->>'legacy', 'false') <> 'true'
           and ev.upstream_status = ev.snap->>'status'
           and not ev.upstream_assignee is distinct from ev.snap->>'assignee'
           and to_jsonb(ev.blockers) = ev.snap->'blockers' as same_as_snapshot,
         ev.comments_after >= 1 and nullif(btrim(ev.upstream_assignee), '') is not null
           and ev.open_blockers >= 1 and ev.unowned_blockers = 0 and ev.self_blockers = 0 as has_evidence
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
  from (select ev.up_id, max(ev.open_blockers) as open_blockers, max(ev.unowned_blockers) as unowned_blockers,
               count(*) filter (where ev.status = 'done') as done_escalations
          from ev group by ev.up_id) g
  join public.work_items u on u.id = g.up_id
 where g.done_escalations > 0 and u.status = 'blocked' and u.updated_at < now() - interval '14 days';

-- cleanup: snapshots the NULL-scope defect stamped on plain tickets ----------------------------------------
-- (the guard would put them back, so it is paused for this one statement)
alter table public.work_items disable trigger trg_escalation_snapshot_guard;
update public.work_items
   set meta = meta - 'escalation_snapshot'
 where meta ? 'escalation_snapshot'
   and not public.escalation_in_scope(title, meta);
alter table public.work_items enable trigger trg_escalation_snapshot_guard;

-- assertions ------------------------------------------------------------------------------------------
do $assert$
begin
  if exists (select 1 from public.work_items where meta ? 'escalation_snapshot' and not public.escalation_in_scope(title, meta)) then
    raise exception 'SB-607: plain tickets still carry an escalation snapshot';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'trg_escalation_snapshot_guard' and tgenabled = 'O'
                  and tgrelid = 'public.work_items'::regclass) then
    raise exception 'SB-607: snapshot guard not re-enabled';
  end if;
  if public.escalation_in_scope('BUG: follow-ups for SB-598', '{"found_by":"x"}'::jsonb)
     or public.escalation_in_scope('plain', null)
     or not public.escalation_in_scope('ESCALATION: SB-1', null)
     or not public.escalation_in_scope('x', '{"issue_type":"review_block"}'::jsonb)
     or public.escalation_in_scope('ESCALATION: SB-1', '{"issue_type":"handoff_gap"}'::jsonb) then
    raise exception 'SB-607: escalation_in_scope truth table wrong';
  end if;
  if (select prosecdef from pg_proc where oid = 'public.escalation_upstream_id(text,jsonb,uuid,uuid)'::regprocedure)
     or has_function_privilege('anon', 'public.escalation_upstream_id(text,jsonb,uuid,uuid)', 'execute') then
    raise exception 'SB-607: escalation_upstream_id is still SECURITY DEFINER or anon-executable';
  end if;
  if (select array_agg(a.attname::text order by a.attname)
        from pg_trigger g join pg_attribute a on a.attrelid = g.tgrelid and a.attnum = any (g.tgattr::int2[])
       where g.tgname = 'trg_escalation_closure' and g.tgrelid = 'public.work_items'::regclass)
     is distinct from array['meta', 'status', 'title'] then
    raise exception 'SB-607: trg_escalation_closure does not fire on status, title and meta';
  end if;
  if position('trigger-owned keys are never caller-supplied' in pg_get_functiondef('public.enforce_escalation_closure()'::regprocedure)) = 0 then
    raise exception 'SB-607: enforce_escalation_closure not replaced';
  end if;
  if not exists (select 1 from pg_class where oid = 'public.vw_escalation_closure_audit'::regclass
                  and reloptions @> array['security_invoker=true']) then
    raise exception 'SB-607: audit view lost security_invoker';
  end if;
  if has_table_privilege('anon', 'public.vw_escalation_closure_audit', 'select') then
    raise exception 'SB-607: anon can read the audit view';
  end if;
end $assert$;
