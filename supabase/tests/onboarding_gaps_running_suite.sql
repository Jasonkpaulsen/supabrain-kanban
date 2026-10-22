-- Onboarding gaps "running" suite: TC-SB625-01, TC-SB625-02 (SB-625). TC-SB625-03 is
-- tests/e2e/project-automation.spec.js plus tests/unit/project-automation-gate.test.ts.
--
-- Run as postgres. One transaction that always ends by raising, so the fixture projects,
-- agents and links it creates do not survive. Pass = the raised message starts with
-- "ONBOARDING_GAPS_RUNNING PASS". The message carries only flags and counts.
--
-- TC-SB625-01: an agent linked only to a paused project is outside the audit even when the
-- project carries a stale meta.dev_automation = 'on'; flipping automation_status to active
-- brings it in (the control), and an agent on an active project with no management agent
-- reports gap_no_project_management.
-- TC-SB625-02: posture. The view text has no dev_automation, security_invoker and grants are
-- as before, no live project carries the retired key, and no public function or view reads it.

do $suite$
declare
  ub constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';   -- owner
  r jsonb := '{}'::jsonb;
  p_paused uuid; p_active uuid; a_paused uuid; a_active uuid;
  n int; fails int; g record;
begin
  -- TC-SB625-02 (live state, before any fixture exists)
  r := r || jsonb_build_object('TC-SB625-02.viewdef',
         case when strpos(pg_get_viewdef('public.vw_agent_onboarding_gaps'::regclass), 'dev_automation') = 0
              then 'pass' else 'FAIL: view reads dev_automation' end);
  r := r || jsonb_build_object('TC-SB625-02.invoker',
         case when (select reloptions from pg_class where oid = 'public.vw_agent_onboarding_gaps'::regclass) = '{security_invoker=true}'::text[]
              then 'pass' else 'FAIL: reloptions changed' end);
  r := r || jsonb_build_object('TC-SB625-02.grants',
         case when (select relacl::text from pg_class where oid = 'public.vw_agent_onboarding_gaps'::regclass)
                   = '{postgres=arwdDxtm/postgres,authenticated=rm/postgres,service_role=arwdDxtm/postgres}'
              then 'pass' else 'FAIL: relacl changed' end);
  select count(*) into n from public.projects where meta ? 'dev_automation';
  r := r || jsonb_build_object('TC-SB625-02.stale_key', case when n = 0 then 'pass' else 'FAIL: ' || n || ' projects carry it' end);
  select count(*) into n from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.prosrc ~ $re$meta\s*->>?\s*'dev_automation'$re$;
  select n + count(*) into n from pg_class c join pg_namespace s on s.oid = c.relnamespace
   where s.nspname = 'public' and c.relkind in ('v', 'm') and pg_get_viewdef(c.oid) ~ $re$'dev_automation'$re$;
  r := r || jsonb_build_object('TC-SB625-02.readers', case when n = 0 then 'pass' else 'FAIL: ' || n || ' readers' end);

  -- TC-SB625-01 fixtures. Not meta.qa_fixture: the view leaves those agents out by design.
  insert into public.projects (name, user_id, domain, automation_status, meta)
  values ('ZZ SB625 paused fixture', ub, 'operations', 'paused', '{"dev_automation": "on"}'::jsonb) returning id into p_paused;
  insert into public.projects (name, user_id, domain, automation_status, meta)
  values ('ZZ SB625 active fixture', ub, 'operations', 'active', '{}'::jsonb) returning id into p_active;
  insert into public.agents (user_id, name, description, system_prompt, status, automation_enabled, reports_to_human, meta)
  values (ub, 'ZZ SB625 paused agent', 'qa-sb625 fixture', 'qa-sb625 fixture prompt', 'active', false, 'Jason', '{"pm_assigned": "qa-sb625"}'::jsonb)
  returning id into a_paused;
  insert into public.agents (user_id, name, description, system_prompt, status, automation_enabled, reports_to_human, meta)
  values (ub, 'ZZ SB625 active agent', 'qa-sb625 fixture', 'qa-sb625 fixture prompt', 'active', false, 'Jason', '{"pm_assigned": "qa-sb625"}'::jsonb)
  returning id into a_active;
  insert into public.agent_projects (agent_id, project_id, user_id) values (a_paused, p_paused, ub), (a_active, p_active, ub);

  select count(*) into n from public.vw_agent_onboarding_gaps where agent_id = a_paused;
  r := r || jsonb_build_object('TC-SB625-01.paused_stale_meta',
         case when n = 0 then 'pass' else 'FAIL: agent on a paused project is audited' end);

  select * into g from public.vw_agent_onboarding_gaps where agent_id = a_active;
  r := r || jsonb_build_object('TC-SB625-01.active_no_mgmt',
         case when g.agent_id is not null and g.gap_no_project_management
                   and g.projects_without_management = array['ZZ SB625 active fixture']
                   and not g.gap_no_reports_to and not g.gap_no_pm
              then 'pass' else 'FAIL: active agent row ' || coalesce(g.gap_no_project_management::text, 'missing') end);

  update public.projects set automation_status = 'active' where id = p_paused;
  select count(*) into n from public.vw_agent_onboarding_gaps where agent_id = a_paused and gap_no_project_management;
  r := r || jsonb_build_object('TC-SB625-01.control',
         case when n = 1 then 'pass' else 'FAIL: activating the project did not bring its agent in' end);

  select count(*) into fails from jsonb_each_text(r) where value <> 'pass';
  if fails = 0 then
    raise exception 'ONBOARDING_GAPS_RUNNING PASS (% checks): %', (select count(*) from jsonb_object_keys(r)), r::text;
  else
    raise exception 'ONBOARDING_GAPS_RUNNING FAIL (% of % checks): %', fails, (select count(*) from jsonb_object_keys(r)), r::text;
  end if;
end $suite$;
