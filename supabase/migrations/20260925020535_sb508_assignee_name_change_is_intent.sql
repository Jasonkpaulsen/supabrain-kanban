-- SB-508: a name-only reassignment was silently reverted by enforce_assignee_integrity.
--
-- The BEFORE INSERT OR UPDATE trigger treated assigned_agent_id as authoritative
-- whenever it was set. An UPDATE that changed only `assignee` on a row that
-- already carried an agent id had its new name overwritten with the OLD agent's
-- name and returned success: updated_at advanced, the caller saw UPDATE 1, and
-- trg_log_assignee_change never fired because OLD and NEW now matched. On
-- 2026-09-24, 340 of 440 open work items carried an agent id, and
-- `SET assignee = '<agent>'` is the documented routing pattern in the scheduled
-- automations -- so routing on those rows was a silent no-op reported as done.
--
-- Fix (System Architect's option (a) on SB-508): on UPDATE, the column the
-- caller changed is the caller's intent.
--   * only the name changed -> the stale id is dropped and the name is resolved
--     exactly as on INSERT: a known agent sets both columns, a cleared or human
--     ("Jason...") assignee clears the id, an unknown name still raises SB-328;
--   * the id changed (alone or together with the name) -> the id stays
--     authoritative and the name is derived from it, as before;
--   * neither changed -> untouched, as before.
-- INSERT behaviour is unchanged. trg_review_assignee still runs after this
-- trigger (triggers fire in name order) and still sets both columns itself.
--
-- The assertion block runs each case against a real open ticket inside its own
-- savepoint and rolls every one of them back, so applying this migration
-- changes the function and nothing else.

CREATE OR REPLACE FUNCTION public.enforce_assignee_integrity()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare v_id uuid; v_name text;
begin
  if TG_OP='UPDATE' and NEW.assignee is not distinct from OLD.assignee
     and NEW.assigned_agent_id is not distinct from OLD.assigned_agent_id then
    return NEW;
  end if;

  -- SB-508: on UPDATE, the column the caller changed is the caller's intent.
  -- If only the name changed, drop the stale id and resolve the new name below.
  if TG_OP='UPDATE' and NEW.assignee is distinct from OLD.assignee
     and NEW.assigned_agent_id is not distinct from OLD.assigned_agent_id then
    NEW.assigned_agent_id := null;
  end if;

  if NEW.assigned_agent_id is not null then
    select name into v_name from agents where id=NEW.assigned_agent_id;
    if v_name is not null then NEW.assignee := v_name; end if;
    return NEW;
  end if;

  if NEW.assignee is null or NEW.assignee='' then return NEW; end if;
  if NEW.assignee ilike 'Jason%' then return NEW; end if;

  select agent_id, agent_name into v_id, v_name from sb328_resolve_agent(NEW.assignee);
  if v_id is null then
    if (select count(*) from agents where status='active' and name ilike '%'||NEW.assignee||'%') = 1 then
      select id, name into v_id, v_name from agents
      where status='active' and name ilike '%'||NEW.assignee||'%';
    end if;
  end if;

  if v_id is null then
    raise exception 'SB-328: assignee "%" matches no agent (exact, alias, id, or unique substring) and is not the human token. Use a canonical agent name.', NEW.assignee;
  end if;

  NEW.assigned_agent_id := v_id;
  NEW.assignee := v_name;
  return NEW;
end $function$;

-- Self-assertion (ADR-DL-003 clause 5). Every probe runs in a savepoint that is
-- rolled back by raising 'rb'; only a genuine failure escapes the block.
do $$
declare
  v_row uuid; v_old_agent uuid; v_new_agent uuid; v_new_name text;
  v_a text; v_u uuid; v_log int; v_err text;
begin
  -- A real open ticket that already carries an agent id, not in progress
  -- (so no WIP gate is involved), and a different active agent to move it to.
  select w.id, w.assigned_agent_id into v_row, v_old_agent
  from public.work_items w
  where w.assigned_agent_id is not null and not coalesce(w.archived, false)
    and w.status in ('todo', 'backlog')
  order by w.created_at limit 1;
  if v_row is null then
    raise notice 'SB-508: no open todo/backlog ticket with an agent id; behavioural probes skipped';
    return;
  end if;
  select a.id, a.name into v_new_agent, v_new_name
  from public.agents a
  where a.status = 'active' and a.id <> v_old_agent
  order by a.name limit 1;

  -- A1: the defect. A name-only reassignment must stick, move the id, and be audited.
  begin
    update public.work_items set assignee = v_new_name where id = v_row;
    select assignee, assigned_agent_id into v_a, v_u from public.work_items where id = v_row;
    select count(*) into v_log from public.activity_log
      where target_id = v_row and meta->>'event' = 'assignee_changed'
        and meta->>'to' = v_new_name and created_at >= now();
    raise exception 'rb';
  exception when raise_exception then
    if sqlerrm <> 'rb' then raise; end if;
  end;
  if v_a is distinct from v_new_name or v_u is distinct from v_new_agent then
    raise exception 'SB-508: name-only reassignment did not stick (assignee=%, id matches=%)', v_a, v_u = v_new_agent;
  end if;
  if v_log < 1 then
    raise exception 'SB-508: reassignment was not recorded in activity_log';
  end if;

  -- A2: an unknown name must still raise SB-328.
  v_err := null;
  begin
    update public.work_items set assignee = 'SB-508 probe: no such agent' where id = v_row;
    v_err := 'accepted';
    raise exception 'rb';
  exception when raise_exception then
    if v_err is null then v_err := sqlerrm; end if;
  end;
  if v_err not like 'SB-328:%' then
    raise exception 'SB-508: an unknown assignee must raise SB-328, got: %', v_err;
  end if;

  -- A3: the human token sticks and clears the id.
  begin
    update public.work_items set assignee = 'Jason Paulsen' where id = v_row;
    select assignee, assigned_agent_id into v_a, v_u from public.work_items where id = v_row;
    raise exception 'rb';
  exception when raise_exception then
    if sqlerrm <> 'rb' then raise; end if;
  end;
  if v_a is distinct from 'Jason Paulsen' or v_u is not null then
    raise exception 'SB-508: human assignee did not stick or kept a stale agent id';
  end if;

  -- A4: an id-only change keeps the id authoritative and derives the name.
  begin
    update public.work_items set assigned_agent_id = v_new_agent where id = v_row;
    select assignee, assigned_agent_id into v_a, v_u from public.work_items where id = v_row;
    raise exception 'rb';
  exception when raise_exception then
    if sqlerrm <> 'rb' then raise; end if;
  end;
  if v_a is distinct from v_new_name or v_u is distinct from v_new_agent then
    raise exception 'SB-508: id-only change no longer derives the name';
  end if;

  -- A5: the probes left nothing behind.
  if (select assigned_agent_id from public.work_items where id = v_row) is distinct from v_old_agent then
    raise exception 'SB-508: probe row was not restored';
  end if;
end $$;
