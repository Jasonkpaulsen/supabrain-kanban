
-- SB-401 decision 1, Jason 2026-08-31: "Top of family escalation chain is Family PM."
--
-- Neither option the ticket offered was right. The question assumed every chain ends
-- at a person and only asked WHICH person. The real answer is that the FAM branch
-- does not reach a person at all: it terminates at Family PM, who then decides what
-- goes further. Family PM's own system_prompt already said this — "You are the sole
-- escalation path from FAM agents to Jason, routed via JARVIS" — so the prose was
-- right and the derivation was wrong.
--
-- The stored chains ending at "Parents (Jason & Mandy)" were therefore ALSO wrong,
-- just wrong in a different direction. Dropping them without asking would have
-- replaced one wrong answer with another.
alter table public.agents
  add column if not exists escalation_ceiling boolean not null default false;

comment on column public.agents.escalation_ceiling is
  'True when escalation from this agent''s subtree stops here rather than continuing to the root (SB-401). The ceiling agent still has its own chain upward.';

update public.agents set escalation_ceiling = true where name = 'Family PM';

-- Walk stops at a ceiling. A ceiling agent starting its own walk is unaffected —
-- the flag governs what happens to agents BELOW it, not to itself.
drop view if exists public.agent_escalation_path;

create view public.agent_escalation_path
with (security_invoker = true) as
with recursive walk as (
  select a.id            as agent_id,
         a.name          as agent_name,
         a.reports_to_agent_id,
         a.reports_to_human,
         0               as hop,
         array[]::text[] as ancestors,
         false           as hit_ceiling
    from public.agents a
  union all
  select w.agent_id, w.agent_name,
         p.reports_to_agent_id, p.reports_to_human,
         w.hop + 1,
         w.ancestors || p.name,
         coalesce(p.escalation_ceiling, false)
    from walk w
    join public.agents p on p.id = w.reports_to_agent_id
   where w.hop < 20
     and not w.hit_ceiling
)
select agent_id,
       agent_name,
       ancestors,
       case when hit_ceiling
            then array[agent_name] || ancestors
            else array[agent_name] || ancestors
                 || case when reports_to_human is not null
                         then array[reports_to_human] else array[]::text[] end
       end                                  as escalation_chain,
       array_length(ancestors, 1)           as hops_to_top,
       hit_ceiling                          as stops_at_ceiling,
       case when hit_ceiling then ancestors[array_length(ancestors,1)]
            else reports_to_human end       as terminates_at,
       (not hit_ceiling and reports_to_human is not null) as reaches_a_person
  from walk
 where hit_ceiling or reports_to_agent_id is null;

comment on view public.agent_escalation_path is
  'Derived escalation chain per agent from agents.reports_to_agent_id (SB-392), terminating at an escalation_ceiling agent where one is set (SB-401), otherwise at reports_to_human. Replaces meta.escalation_chain / escalation_path / escalation_path_defined.';

grant select on public.agent_escalation_path to anon, authenticated, service_role;
;
