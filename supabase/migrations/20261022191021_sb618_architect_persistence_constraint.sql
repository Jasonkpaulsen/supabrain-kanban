-- SB-618: give every active Architect agent the SB-212 architecture-persistence instructions.
--
-- SB-212 wrote the instructions into files on the Mac; agent-runner builds a dispatched
-- agent's prompt from system_prompt, goals and constraints only, so no dispatched Architect
-- ever saw them. Jason chose (2026-10-22, authority L2 agent_config_change, recorded in
-- governance_audit) one identical constraint item on each Architect, rather than a
-- system_prompt section (most prompts end in a generated chain-of-command block) or no
-- change. The canonical text is docs/skills/architect-architecture-persistence.md; md5
-- 8c0a4445cb79bf95788b7564a1ff8634. Idempotent: an Architect that already has the item is
-- left alone. Nothing else in the rows changes, which the assertion block checks.

create temp table sb618_before as
select id, name, md5(coalesce(system_prompt, '')) p, md5(coalesce(goals::text, '')) g, coalesce(constraints, '{}') c
  from public.agents where status = 'active' and name like '%Architect';

update public.agents a
   set constraints = coalesce(a.constraints, '{}') || array[$constraint$ARCHITECTURE PERSISTENCE (SB-212, SB-618): before designing, read the project's standing decisions: select * from vw_project_architecture where project_key = '<KEY>' order by domain, version desc. Record every architecture decision you make or change as one row in public.decisions: project_id, title, decision, reasoning, alternatives_considered, domain (app_shell | data_layer | ai_runtime | audio_pipeline | security | build_distribution | platform_abstraction | api_integration | ui_ux | testing | monitoring | compliance | infrastructure), status 'proposed' until accepted, and the ticket's work_item_id. To change one, insert a new version with supersedes_id and mark the old row 'superseded'; never edit an accepted decision in place. Ecosystem-wide decisions also get an ADR file: docs/adr/ADR-<AREA>-NNN-<slug>.md in supabrain-kanban.$constraint$]
 where a.status = 'active' and a.name like '%Architect'
   and not exists (select 1 from unnest(coalesce(a.constraints, '{}')) c where c like 'ARCHITECTURE PERSISTENCE (SB-212%');

do $assert$
declare n int; bad text;
begin
  select string_agg(name, ', ' order by name) into bad from sb618_before;
  if bad is distinct from 'CIP Architect, CS Architect, DEN Architect, Kalshi Architect, Local AI Architect, System Architect' then
    raise exception 'SB-618: the active Architects are not the six Jason approved: %', bad;
  end if;
  select count(*) into n from public.agents a
   where a.status = 'active' and a.name like '%Architect'
     and (select count(*) from unnest(a.constraints) c where c like 'ARCHITECTURE PERSISTENCE (SB-212%') = 1
     and (select md5(c) from unnest(a.constraints) c where c like 'ARCHITECTURE PERSISTENCE (SB-212%') = '8c0a4445cb79bf95788b7564a1ff8634';
  if n <> 6 then
    raise exception 'SB-618: % of 6 Architects carry the constraint exactly once with the canonical text', n;
  end if;
  select string_agg(b.name, ', ') into bad from sb618_before b join public.agents a on a.id = b.id
   where md5(coalesce(a.system_prompt, '')) <> b.p or md5(coalesce(a.goals::text, '')) <> b.g
      or array_remove(a.constraints, (select c from unnest(a.constraints) c where c like 'ARCHITECTURE PERSISTENCE (SB-212%'))
         is distinct from array_remove(b.c, (select c from unnest(b.c) c where c like 'ARCHITECTURE PERSISTENCE (SB-212%'));
  if bad is not null then
    raise exception 'SB-618: something other than the new constraint changed on: %', bad;
  end if;
end
$assert$;
