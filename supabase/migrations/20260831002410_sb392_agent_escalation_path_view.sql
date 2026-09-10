
-- SB-392: an escalation chain is a path through the org chart, not a field.
--
-- Three keys described it — escalation_chain (55 agents), escalation_path_defined
-- (46), escalation_path (36) — and no consumer read all three. Now that SB-391
-- made the chart a foreign key, the path is derivable exactly.
create or replace view public.agent_escalation_path
with (security_invoker = true) as
with recursive walk as (
  select a.id                as agent_id,
         a.name              as agent_name,
         a.reports_to_agent_id,
         a.reports_to_human,
         0                   as hop,
         array[]::text[]     as chain
    from public.agents a
  union all
  select w.agent_id,
         w.agent_name,
         p.reports_to_agent_id,
         p.reports_to_human,
         w.hop + 1,
         w.chain || p.name
    from walk w
    join public.agents p on p.id = w.reports_to_agent_id
   where w.hop < 20
)
select agent_id,
       agent_name,
       chain                                        as escalation_chain,
       array_length(chain, 1)                       as chain_length,
       reports_to_human                             as terminates_at_human,
       (reports_to_human is not null)               as reaches_a_person
  from walk
 where reports_to_agent_id is null   -- only the terminal row of each walk
;

comment on view public.agent_escalation_path is
  'Derived escalation chain per agent: the ordered ancestor list from agents.reports_to_agent_id, terminating at reports_to_human (SB-392). Replaces meta.escalation_chain / escalation_path / escalation_path_defined.';

grant select on public.agent_escalation_path to anon, authenticated, service_role;
;
