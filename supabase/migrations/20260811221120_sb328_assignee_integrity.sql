-- SB-328: assignee is free text counted by name (WIP limits, dispatch, SLA), so drift
-- makes work invisible to the machinery. Observed live: raw agent UUIDs in assignee,
-- shorthand names, and 7+ spellings in test_cases.last_tested_by.
create or replace function public.resolve_agent(p_name text)
returns table(agent_id uuid, agent_name text)
language sql stable set search_path to 'public' as $$
  select a.id, a.name from agents a
  where a.status='active' and (
        a.name = p_name
     or lower(a.name) = lower(p_name)
     or lower(coalesce(a.alias,'')) = lower(p_name)
     or a.id::text = p_name)
  limit 1
$$;

create or replace function public.enforce_assignee_integrity()
returns trigger language plpgsql set search_path to 'public' as $$
declare v_id uuid; v_name text;
begin
  -- Only act when the assignment actually changed
  if TG_OP='UPDATE' and NEW.assignee is not distinct from OLD.assignee
     and NEW.assigned_agent_id is not distinct from OLD.assigned_agent_id then
    return NEW;
  end if;

  -- The id is authoritative: name always derived from it
  if NEW.assigned_agent_id is not null then
    select name into v_name from agents where id=NEW.assigned_agent_id;
    if v_name is not null then NEW.assignee := v_name; end if;
    return NEW;
  end if;

  if NEW.assignee is null or NEW.assignee='' then return NEW; end if;

  -- Human token (ADR-IDENT-001): Jason variants pass untouched
  if NEW.assignee ilike 'Jason%' then return NEW; end if;

  select agent_id, agent_name into v_id, v_name from resolve_agent(NEW.assignee);
  if v_id is null then
    -- last resort: unique substring match ('License Sentinel' -> 'CIP License Sentinel')
    select id, name into v_id, v_name from agents
    where status='active' and name ilike '%'||NEW.assignee||'%'
    having count(*) over () >= 0 limit 1;
    if (select count(*) from agents where status='active' and name ilike '%'||NEW.assignee||'%') <> 1 then
      v_id := null;
    end if;
  end if;

  if v_id is null then
    raise exception 'SB-328: assignee "%" matches no agent (exact, alias, id, or unique substring) and is not the human token. Use a canonical agent name.', NEW.assignee;
  end if;

  NEW.assigned_agent_id := v_id;
  NEW.assignee := v_name;
  return NEW;
end $$;

drop trigger if exists trg_assignee_integrity on public.work_items;
create trigger trg_assignee_integrity
  before insert or update on public.work_items
  for each row execute function public.enforce_assignee_integrity();

-- test_cases.last_tested_by: canonicalize when resolvable, never reject (humans and
-- historical externals are legitimate values there).
create or replace function public.normalize_tester_name()
returns trigger language plpgsql set search_path to 'public' as $$
declare v_name text;
begin
  if NEW.last_tested_by is not null and NEW.last_tested_by <> '' then
    select agent_name into v_name from resolve_agent(NEW.last_tested_by);
    if v_name is not null then NEW.last_tested_by := v_name; end if;
  end if;
  return NEW;
end $$;

drop trigger if exists trg_tester_name on public.test_cases;
create trigger trg_tester_name
  before insert or update on public.test_cases
  for each row execute function public.normalize_tester_name();;
