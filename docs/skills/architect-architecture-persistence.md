# Architect agents: architecture persistence (SB-212, SB-618)

Every active Architect agent (an active agent whose name ends in "Architect") carries the
constraint below, exactly once, as one item of `agents.constraints`. agent-runner builds a
dispatched agent's prompt from `system_prompt`, `goals` and `constraints` only, so a
constraint is what a dispatched Architect actually reads; linked skills and the Mac SKILL
files are not injected. The text is kept out of `system_prompt` because the
`## CHAIN OF COMMAND (generated…)` block at the end of most prompts is rewritten by a trigger.

Jason chose this placement on 2026-10-22 (authority L2, `agent_config_change`; recorded in
`governance_audit`). To change the text: edit it here, write a migration that replaces the
old item on every Architect, and update the md5 in
`supabase/tests/architect_persistence_suite.sql`. `tests/unit/architect-persistence.test.ts`
fails until all three agree.

## The constraint

The text between the markers is the constraint, byte for byte (one line, no trailing space).

<!-- BEGIN ARCHITECT PERSISTENCE CONSTRAINT -->
ARCHITECTURE PERSISTENCE (SB-212, SB-618): before designing, read the project's standing decisions: select * from vw_project_architecture where project_key = '<KEY>' order by domain, version desc. Record every architecture decision you make or change as one row in public.decisions: project_id, title, decision, reasoning, alternatives_considered, domain (app_shell | data_layer | ai_runtime | audio_pipeline | security | build_distribution | platform_abstraction | api_integration | ui_ux | testing | monitoring | compliance | infrastructure), status 'proposed' until accepted, and the ticket's work_item_id. To change one, insert a new version with supersedes_id and mark the old row 'superseded'; never edit an accepted decision in place. Ecosystem-wide decisions also get an ADR file: docs/adr/ADR-<AREA>-NNN-<slug>.md in supabrain-kanban.
<!-- END ARCHITECT PERSISTENCE CONSTRAINT -->

## Checking it

```sql
-- every active Architect, its copy of the constraint, and whether it matches
select a.name, count(c) filter (where c like 'ARCHITECTURE PERSISTENCE (SB-212%') copies,
       bool_and(md5(c) = '<md5 from the suite>') filter (where c like 'ARCHITECTURE PERSISTENCE (SB-212%') matches
  from agents a left join lateral unnest(a.constraints) c on true
 where a.status = 'active' and a.name like '%Architect'
 group by a.name;
```

`supabase/tests/architect_persistence_suite.sql` runs this check and more.
