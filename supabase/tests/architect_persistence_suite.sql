-- Architect persistence suite: TC-SB618-01, TC-SB618-02 (SB-618). TC-SB618-03 is
-- tests/unit/architect-persistence.test.ts.
--
-- Run as postgres. Read-only; it always ends by raising. Pass = the raised message starts
-- with "ARCHITECT_PERSISTENCE PASS". The message carries only agent names and counts.
--
-- Every active agent whose name ends in "Architect" must carry the SB-212 persistence
-- constraint exactly once, byte-identical to docs/skills/architect-architecture-persistence.md
-- (md5 below). A new Architect created without it fails this suite. TC-SB618-02 builds the
-- prompt the way agent-runner does (system_prompt, then Goals, then Constraints) and checks
-- the instruction is in what a dispatched Architect reads.

do $suite$
declare
  canonical constant text := '8c0a4445cb79bf95788b7564a1ff8634';
  r jsonb := '{}'::jsonb; n int; m int; fails int; bad text;
begin
  -- TC-SB618-01
  select count(*),
         string_agg(a.name || ' (' || (select count(*) from unnest(coalesce(a.constraints, '{}')) c where c like 'ARCHITECTURE PERSISTENCE (SB-212%') || ')', ', ')
           filter (where (select count(*) from unnest(coalesce(a.constraints, '{}')) c
                           where c like 'ARCHITECTURE PERSISTENCE (SB-212%' and md5(c) = canonical) <> 1
                      or (select count(*) from unnest(coalesce(a.constraints, '{}')) c where c like 'ARCHITECTURE PERSISTENCE (SB-212%') <> 1)
    into n, bad
    from public.agents a where a.status = 'active' and a.name like '%Architect';
  r := r || jsonb_build_object('TC-SB618-01.every_architect',
         case when n >= 6 and bad is null then 'pass' else 'FAIL: ' || n || ' architects; wrong: ' || coalesce(bad, 'too few architects') end);
  r := r || jsonb_build_object('TC-SB618-01.evidence', n || ' active Architects');

  -- TC-SB618-02: what agent-runner would send carries it, once
  select count(*) filter (where (length(prompt) - length(replace(prompt, 'ARCHITECTURE PERSISTENCE (SB-212', ''))) / length('ARCHITECTURE PERSISTENCE (SB-212') = 1),
         count(*)
    into m, n
    from (select coalesce(a.system_prompt, '')
                 || case when cardinality(a.goals) > 0 then E'\n\nGoals:\n- ' || array_to_string(a.goals, E'\n- ') else '' end
                 || case when cardinality(a.constraints) > 0 then E'\n\nConstraints:\n- ' || array_to_string(a.constraints, E'\n- ') else '' end prompt
            from public.agents a where a.status = 'active' and a.name like '%Architect') x;
  r := r || jsonb_build_object('TC-SB618-02.in_dispatched_prompt', case when m = n then 'pass' else 'FAIL: ' || m || ' of ' || n end);
  select count(*) into n from public.agents a
   where a.status = 'active' and a.name like '%Architect' and not coalesce(trim(a.system_prompt), '') <> '';
  r := r || jsonb_build_object('TC-SB618-02.prompts_present', case when n = 0 then 'pass' else 'FAIL: ' || n || ' empty prompts' end);
  -- the instruction names objects that exist
  r := r || jsonb_build_object('TC-SB618-02.objects_exist',
         case when to_regclass('public.vw_project_architecture') is not null and to_regclass('public.decisions') is not null
                   and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'decisions' and column_name = 'supersedes_id')
              then 'pass' else 'FAIL: decisions or vw_project_architecture missing' end);

  select count(*) into fails from jsonb_each_text(r) where key not like '%.evidence' and value <> 'pass';
  if fails = 0 then
    raise exception 'ARCHITECT_PERSISTENCE PASS (% checks): %', (select count(*) from jsonb_object_keys(r) k where k not like '%.evidence'), r::text;
  else
    raise exception 'ARCHITECT_PERSISTENCE FAIL (% of % checks): %', fails, (select count(*) from jsonb_object_keys(r) k where k not like '%.evidence'), r::text;
  end if;
end $suite$;
