
-- SB-392 step 2 finding: the stored chains use [self, ...ancestors, human].
-- The first cut of this view emitted ancestors only, which made all 55 stored
-- chains look like disagreements when they were a format mismatch. Emitting the
-- established shape instead — and keeping the bare ancestor list beside it, since
-- that is what a walk actually needs.
--
-- Inconsistency worth recording: some stored chains open with the literal string
-- "self", others repeat the agent's own name. Both mean the same thing.
drop view if exists public.agent_escalation_path;

create view public.agent_escalation_path
with (security_invoker = true) as
with recursive walk as (
  select a.id                as agent_id,
         a.name              as agent_name,
         a.reports_to_agent_id,
         a.reports_to_human,
         0                   as hop,
         array[]::text[]     as ancestors
    from public.agents a
  union all
  select w.agent_id, w.agent_name, p.reports_to_agent_id, p.reports_to_human,
         w.hop + 1, w.ancestors || p.name
    from walk w
    join public.agents p on p.id = w.reports_to_agent_id
   where w.hop < 20
)
select agent_id,
       agent_name,
       ancestors,
       (array[agent_name] || ancestors
         || case when reports_to_human is not null then array[reports_to_human] else array[]::text[] end
       ) as escalation_chain,
       array_length(ancestors, 1)      as hops_to_root,
       reports_to_human                as terminates_at_human,
       (reports_to_human is not null)  as reaches_a_person
  from walk
 where reports_to_agent_id is null;

comment on view public.agent_escalation_path is
  'Derived escalation chain per agent from agents.reports_to_agent_id (SB-392). escalation_chain uses the [self, ...ancestors, human] convention the retired meta.escalation_chain used; ancestors is the bare walk. Replaces meta.escalation_chain / escalation_path / escalation_path_defined.';

grant select on public.agent_escalation_path to anon, authenticated, service_role;
;
