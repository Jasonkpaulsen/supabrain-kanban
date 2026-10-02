
-- SB-391 step 4: the chart is a tree; say so.
create or replace function public.enforce_agent_chart_acyclic()
returns trigger
language plpgsql
set search_path to 'public'
as $fn$
declare
  v_cursor uuid := new.reports_to_agent_id;
  v_hops   int  := 0;
begin
  if new.reports_to_agent_id is null then
    return new;
  end if;

  if new.reports_to_agent_id = new.id then
    raise exception 'agent % cannot report to itself', new.name
      using errcode = 'check_violation';
  end if;

  -- Walk to the root. 85 agents today, so the hop cap is a runaway guard, not a
  -- depth limit: a cycle that predates this trigger would otherwise spin here.
  while v_cursor is not null and v_hops < 100 loop
    if v_cursor = new.id then
      raise exception 'agent % would become its own ancestor', new.name
        using errcode = 'check_violation';
    end if;
    select reports_to_agent_id into v_cursor from public.agents where id = v_cursor;
    v_hops := v_hops + 1;
  end loop;

  if v_hops >= 100 then
    raise exception 'org chart walk exceeded 100 hops from agent % — pre-existing cycle', new.name
      using errcode = 'check_violation';
  end if;

  return new;
end;
$fn$;

drop trigger if exists trg_agent_chart_acyclic on public.agents;
create trigger trg_agent_chart_acyclic
  before insert or update of reports_to_agent_id on public.agents
  for each row execute function public.enforce_agent_chart_acyclic();

-- SB-391 step 5: the reverse edge is DERIVED. meta.directs was hand-maintained
-- and populated on 6 of 81 agents; SB-385 was one instance of it going stale and
-- the fix for SB-385 was another. A view cannot go stale.
create or replace view public.agent_directs
with (security_invoker = true) as
select
  p.id                as agent_id,
  p.name              as agent_name,
  d.id                as direct_id,
  d.name              as direct_name,
  d.status            as direct_status,
  d.meta->>'tier'     as direct_tier,
  d.meta->>'domain'   as direct_domain
from public.agents p
join public.agents d on d.reports_to_agent_id = p.id;

comment on view public.agent_directs is
  'Derived reverse edge of agents.reports_to_agent_id (SB-391). Replaces the hand-maintained meta.directs. Never store this.';

grant select on public.agent_directs to anon, authenticated, service_role;
;
