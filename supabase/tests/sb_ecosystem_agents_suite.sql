-- SB ecosystem agents suite: TC-SB619-01 (SB-619), and the amended TC-SB153-01.
--
-- Run as postgres. Read-only; it always ends by raising. Pass = the raised message starts
-- with "SB_ECOSYSTEM_AGENTS PASS". The message carries only agent names, roles and counts.
--
-- SB-153 asked for five "cross-cutting" agents on project SB. Four are ecosystem-wide and
-- are linked: JARVIS, System Architect, SupaBrain Process Engineer, SupaBrain QA. The fifth,
-- 39P Operations Manager, is a management agent scoped to 39 Powers; linking it would make
-- the onboarding audit count it as management coverage for SB. Jason chose (2026-10-22, L2)
-- not to link it. This suite holds both halves of that decision, and the rule behind it: a
-- management-tier agent linked to SB must be scoped to SB.

do $suite$
declare
  sb constant uuid := 'a07a7f3d-722f-468f-81fa-84e2c5fba704';
  ops39 constant uuid := 'b39f0000-3900-4000-b000-000039000001';
  r jsonb := '{}'::jsonb; n int; fails int; bad text;
begin
  -- TC-SB153-01 (amended): the 4 ecosystem agents are active and linked to SB
  select count(*), string_agg(e.name, ', ') filter (where ap.agent_id is null or a.status <> 'active') into n, bad
    from unnest(array['JARVIS — Master Orchestrator', 'System Architect', 'SupaBrain Process Engineer', 'SupaBrain QA']) e(name)
    left join public.agents a on a.name = e.name
    left join public.agent_projects ap on ap.agent_id = a.id and ap.project_id = sb;
  r := r || jsonb_build_object('TC-SB153-01.ecosystem_on_sb', case when bad is null then 'pass' else 'FAIL: missing or inactive: ' || bad end);

  -- TC-SB619-01: 39P Operations Manager stays on 39P, and only there
  select count(*), string_agg(p.project_key, ',') into n, bad
    from public.agent_projects ap join public.projects p on p.id = ap.project_id where ap.agent_id = ops39;
  r := r || jsonb_build_object('TC-SB619-01.ops39_scope', case when n = 1 and bad = '39P' then 'pass' else 'FAIL: linked to ' || coalesce(bad, 'nothing') end);

  -- TC-SB619-01: every management-tier agent on SB is scoped to SB
  select count(*), string_agg(a.name || ' (' || coalesce(a.meta ->> 'scope', 'no scope') || ')', ', ') into n, bad
    from public.agent_projects ap join public.agents a on a.id = ap.agent_id
   where ap.project_id = sb and a.status = 'active' and a.meta ->> 'tier' = 'management'
     and coalesce(a.meta ->> 'scope', '') <> 'SB';
  r := r || jsonb_build_object('TC-SB619-01.sb_management_scoped', case when n = 0 then 'pass' else 'FAIL: ' || bad end);

  select count(*) into fails from jsonb_each_text(r) where value <> 'pass';
  if fails = 0 then
    raise exception 'SB_ECOSYSTEM_AGENTS PASS (% checks): %', (select count(*) from jsonb_object_keys(r)), r::text;
  else
    raise exception 'SB_ECOSYSTEM_AGENTS FAIL (% of % checks): %', fails, (select count(*) from jsonb_object_keys(r)), r::text;
  end if;
end $suite$;
