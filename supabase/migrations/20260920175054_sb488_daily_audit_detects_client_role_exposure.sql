-- SB-488 (half A): the daily audit detects client-role exposure.
--
-- SB-479 was found by someone reading the Supabase advisor page. Nothing in this
-- project's own audit looked at RLS or at grants, so an anon-writable table sat in
-- production for twenty days. This adds three report-only checks to the Process
-- Engineer daily audit (generate_daily_audit) and the baseline they compare to:
--
--   1. any table in public with RLS disabled;
--   2. any privilege anon or authenticated holds on a table or function in public
--      that is not in the baseline -- i.e. a grant that appeared since the last
--      audit, whether from a migration, the dashboard, or a default;
--   3. any SECURITY DEFINER function in public that anon can execute.
--
-- Report, do not block: findings land in process_audits.governance_violations
-- under 'security_exposure' and raise violations_count, which is what makes the
-- audit's max_severity 'high'. Nothing is revoked automatically; a finding is a
-- ticket for a person.
--
-- The baseline is seeded here with every client-role grant that exists today, so
-- day one is quiet. Each later run records the grants it reports, so a grant is
-- reported once, on the day it appears, and then becomes part of the baseline.
-- Removing a row from security_grant_baseline makes the audit report that grant
-- again; that is the intended way to re-raise one.
--
-- Two defects caught by this migration's own assertion before it ever recorded.
-- First draft: c.relname (type name, 63 bytes) in a UNION with the function
-- names truncated every long function name in the baseline; nineteen functions
-- were reported as new. Fixed with explicit ::text casts. Second draft: the seed
-- ran as a top-level statement, where pg_get_function_identity_arguments renders
-- a vector argument as "vector" because extensions is on the search_path, while
-- the audit function runs with search_path = '' and renders "extensions.vector";
-- three signatures never matched. Fixed by seeding THROUGH the audit function, so
-- the baseline is written by the same code, under the same search_path, that
-- later reads it. Kept here because "the assertion caught it" is the reason the
-- assertion exists.
--
-- This migration runs after half B, so the two objects it creates are also the
-- first evidence that half B holds: the DO block asserts that neither the table
-- nor the function received any anon or authenticated privilege on creation.

create table if not exists public.security_grant_baseline (
  object_type text not null check (object_type in ('table', 'function')),
  object_name text not null,
  grantee     text not null check (grantee in ('anon', 'authenticated')),
  privilege   text not null,
  first_seen  date not null default current_date,
  source      text not null default 'audit',
  primary key (object_type, object_name, grantee, privilege)
);

comment on table public.security_grant_baseline is
  'SB-488: every privilege anon/authenticated held on a public table or function the last time the daily audit ran. The audit reports and then records anything not in here. Delete a row to make the audit re-raise that grant.';

alter table public.security_grant_baseline enable row level security;

create or replace function public.audit_client_role_exposure(p_record boolean default true)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_rls    jsonb;
  v_new    jsonb;
  v_secdef jsonb;
  v_count  int;
begin
  -- 1. Tables in public with RLS disabled.
  select coalesce(jsonb_agg(c.relname::text order by c.relname), '[]'::jsonb)
    into v_rls
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;

  -- 2. Client-role grants not yet in the baseline.
  with current_grants as (
    select 'table'::text as object_type, c.relname::text as object_name, r.grantee, p.privilege
      from pg_catalog.pg_class c
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
     cross join (values ('anon'), ('authenticated')) as r(grantee)
     cross join (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'),
                        ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) as p(privilege)
     where n.nspname = 'public' and c.relkind = 'r'
       and pg_catalog.has_table_privilege(r.grantee, c.oid, p.privilege)
    union all
    select 'function'::text, f.proname::text || '(' || pg_catalog.pg_get_function_identity_arguments(f.oid) || ')', r.grantee, 'EXECUTE'
      from pg_catalog.pg_proc f
      join pg_catalog.pg_namespace n on n.oid = f.pronamespace
     cross join (values ('anon'), ('authenticated')) as r(grantee)
     where n.nspname = 'public'
       and pg_catalog.has_function_privilege(r.grantee, f.oid, 'EXECUTE')
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'object', g.object_type || ' ' || g.object_name,
           'grantee', g.grantee, 'privilege', g.privilege)
           order by g.object_type, g.object_name, g.grantee, g.privilege), '[]'::jsonb)
    into v_new
    from current_grants g
    left join public.security_grant_baseline b
      on b.object_type = g.object_type and b.object_name = g.object_name
     and b.grantee = g.grantee and b.privilege = g.privilege
   where b.object_name is null;

  if p_record then
    insert into public.security_grant_baseline (object_type, object_name, grantee, privilege)
    select 'table'::text, c.relname::text, r.grantee, p.privilege
      from pg_catalog.pg_class c
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
     cross join (values ('anon'), ('authenticated')) as r(grantee)
     cross join (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'),
                        ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) as p(privilege)
     where n.nspname = 'public' and c.relkind = 'r'
       and pg_catalog.has_table_privilege(r.grantee, c.oid, p.privilege)
    union all
    select 'function'::text, f.proname::text || '(' || pg_catalog.pg_get_function_identity_arguments(f.oid) || ')', r.grantee, 'EXECUTE'
      from pg_catalog.pg_proc f
      join pg_catalog.pg_namespace n on n.oid = f.pronamespace
     cross join (values ('anon'), ('authenticated')) as r(grantee)
     where n.nspname = 'public'
       and pg_catalog.has_function_privilege(r.grantee, f.oid, 'EXECUTE')
    on conflict do nothing;
  end if;

  -- 3. SECURITY DEFINER functions anon can execute.
  select coalesce(jsonb_agg(f.proname::text || '(' || pg_catalog.pg_get_function_identity_arguments(f.oid) || ')' order by f.proname), '[]'::jsonb)
    into v_secdef
    from pg_catalog.pg_proc f
    join pg_catalog.pg_namespace n on n.oid = f.pronamespace
   where n.nspname = 'public' and f.prosecdef
     and pg_catalog.has_function_privilege('anon', f.oid, 'EXECUTE');

  v_count := jsonb_array_length(v_rls) + jsonb_array_length(v_new) + jsonb_array_length(v_secdef);

  return jsonb_build_object(
    'rls_disabled_tables', v_rls,
    'new_client_grants', v_new,
    'anon_executable_security_definer', v_secdef,
    'finding_count', v_count,
    'checked_at', pg_catalog.clock_timestamp()::text
  );
end;
$fn$;

comment on function public.audit_client_role_exposure(boolean) is
  'SB-488: report-only. RLS-disabled tables, client-role grants not in security_grant_baseline (recorded after reporting when p_record), anon-executable SECURITY DEFINER functions. Called by generate_daily_audit.';

revoke execute on function public.audit_client_role_exposure(boolean) from public, anon, authenticated;
grant execute on function public.audit_client_role_exposure(boolean) to service_role;

-- Seed the baseline THROUGH the audit function (see header), then mark the rows.
select public.audit_client_role_exposure(true);
update public.security_grant_baseline set source = 'sb488_seed' where source = 'audit';

-- Wire the check into the daily audit. The generate_daily_audit body below is
-- the 20260802 (SB-287) body with four additions, each marked SB-488.
CREATE OR REPLACE FUNCTION public.generate_daily_audit(p_user_id uuid, p_project_id uuid, p_audit_date date DEFAULT CURRENT_DATE, p_auditor_agent_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_id uuid;
  v_flow jsonb;
  v_gov jsonb;
  v_agents jsonb;
  v_qa jsonb;
  v_sec jsonb;            -- SB-488
  v_recs int;
  v_flags int;
  v_violations int;
  v_max_sev text;
  v_ticket_codes text[];
  v_agent_ids uuid[];
  v_snapshot_ts timestamptz;
BEGIN
  -- Record the snapshot timestamp for traceability
  v_snapshot_ts := clock_timestamp();

  -- =========================================================
  -- PHASE 1: Snapshot base data into temp tables.
  -- All subsequent metric queries read ONLY from these snapshots.
  -- This eliminates cross-statement read inconsistency (SB-287).
  -- =========================================================

  CREATE TEMP TABLE _audit_wi ON COMMIT DROP AS
    SELECT id, status, assigned_agent_id, assignee, approval_status,
           description, priority, due_date, ticket_code, type, meta,
           created_at, updated_at, completed_at
      FROM public.work_items
     WHERE user_id = p_user_id AND project_id = p_project_id;

  CREATE TEMP TABLE _audit_tc ON COMMIT DROP AS
    SELECT id, work_item_id, status
      FROM public.test_cases
     WHERE user_id = p_user_id AND project_id = p_project_id;

  CREATE TEMP TABLE _audit_agents ON COMMIT DROP AS
    SELECT a.id
      FROM public.agents a
      JOIN public.agent_projects ap ON ap.agent_id = a.id AND ap.project_id = p_project_id
     WHERE a.user_id = p_user_id;

  -- =========================================================
  -- PHASE 2: Compute all metrics from the snapshots.
  -- =========================================================

  -- Flow metrics
  SELECT jsonb_build_object(
    'total_items', COUNT(*),
    'backlog', COUNT(*) FILTER (WHERE status = 'backlog'),
    'todo', COUNT(*) FILTER (WHERE status = 'todo'),
    'in_progress', COUNT(*) FILTER (WHERE status = 'in_progress'),
    'review', COUNT(*) FILTER (WHERE status = 'review'),
    'done', COUNT(*) FILTER (WHERE status = 'done'),
    'done_today', COUNT(*) FILTER (WHERE status = 'done' AND completed_at::date = p_audit_date),
    'created_today', COUNT(*) FILTER (WHERE created_at::date = p_audit_date),
    'updated_today', COUNT(*) FILTER (WHERE updated_at::date = p_audit_date),
    'stale_14d', COUNT(*) FILTER (WHERE updated_at < (p_audit_date - 14) AND status NOT IN ('done','backlog')),
    'blocked', COUNT(*) FILTER (WHERE status = 'in_progress' AND updated_at < (p_audit_date - 7)),
    'unassigned', COUNT(*) FILTER (WHERE assigned_agent_id IS NULL AND status NOT IN ('done','backlog')),
    'overdue', COUNT(*) FILTER (WHERE due_date < p_audit_date AND status != 'done'),
    'avg_age_days', COALESCE(AVG(p_audit_date - created_at::date) FILTER (WHERE status NOT IN ('done','backlog')), 0)::int
  ) INTO v_flow
  FROM _audit_wi;

  -- Governance violations
  SELECT jsonb_build_object(
    'missing_description', COUNT(*) FILTER (WHERE (description IS NULL OR description = '') AND status NOT IN ('backlog')),
    'missing_priority', COUNT(*) FILTER (WHERE priority IS NULL),
    'unapproved_past_gate', COUNT(*) FILTER (WHERE status IN ('in_progress','review','done') AND approval_status NOT IN ('approved','not_required'))
  ),
  (COUNT(*) FILTER (WHERE (description IS NULL OR description = '') AND status NOT IN ('backlog')))
    + (COUNT(*) FILTER (WHERE status IN ('in_progress','review','done') AND approval_status NOT IN ('approved','not_required')))
  INTO v_gov, v_violations
  FROM _audit_wi;

  -- SB-488: client-role exposure. Schema-wide, not per project, because grants
  -- and RLS are not partitioned by project. Report-only; each finding counts as
  -- a violation so max_severity surfaces it.
  v_sec := public.audit_client_role_exposure(true);
  v_gov := v_gov || jsonb_build_object('security_exposure', v_sec);
  v_violations := v_violations + COALESCE((v_sec->>'finding_count')::int, 0);

  -- Agent utilization
  SELECT jsonb_build_object(
    'total_agents', COUNT(DISTINCT a.id),
    'agents_with_work', (SELECT COUNT(DISTINCT w2.assigned_agent_id) FROM _audit_wi w2 WHERE w2.status NOT IN ('done','backlog') AND w2.assigned_agent_id IS NOT NULL),
    'total_open_items', (SELECT COUNT(*) FROM _audit_wi w3 WHERE w3.status NOT IN ('done','backlog'))
  ) INTO v_agents
  FROM _audit_agents a;

  -- QA coverage
  SELECT jsonb_build_object(
    'total_test_cases', COUNT(*),
    'passed', COUNT(*) FILTER (WHERE status = 'passed'),
    'failed', COUNT(*) FILTER (WHERE status = 'failed'),
    'pending', COUNT(*) FILTER (WHERE status IN ('pending','draft')),
    'pass_rate', CASE WHEN COUNT(*) FILTER (WHERE status IN ('passed','failed')) > 0
      THEN ROUND(COUNT(*) FILTER (WHERE status = 'passed')::numeric / COUNT(*) FILTER (WHERE status IN ('passed','failed')) * 100, 1)
      ELSE 0 END
  ) INTO v_qa
  FROM _audit_tc;

  -- Recommendations/flags from latest briefing (external table — single read, acceptable)
  SELECT
    COALESCE(jsonb_array_length(recommendations), 0),
    COALESCE(jsonb_array_length(flags), 0)
  INTO v_recs, v_flags
  FROM public.jarvis_briefings
  WHERE user_id = p_user_id
  ORDER BY briefing_date DESC LIMIT 1;

  v_recs := COALESCE(v_recs, 0);
  v_flags := COALESCE(v_flags, 0);
  v_max_sev := CASE
    WHEN v_violations > 0 THEN 'high'
    WHEN v_flags > 2 THEN 'medium'
    WHEN v_flags > 0 THEN 'low'
    ELSE 'info'
  END;

  -- Flagged ticket codes (from snapshot)
  SELECT array_agg(ticket_code) INTO v_ticket_codes
  FROM _audit_wi
  WHERE ((due_date < p_audit_date AND status != 'done')
      OR (updated_at < (p_audit_date - 14) AND status NOT IN ('done','backlog')))
    AND ticket_code IS NOT NULL;

  -- Active agent IDs (from snapshot)
  SELECT array_agg(DISTINCT assigned_agent_id) INTO v_agent_ids
  FROM _audit_wi
  WHERE assigned_agent_id IS NOT NULL AND status NOT IN ('done','backlog');

  -- =========================================================
  -- PHASE 3: Insert/upsert the audit record.
  -- =========================================================
  INSERT INTO public.process_audits (
    user_id, project_id, auditor_agent_id, audit_type, audit_date, status,
    governance_violations, flow_metrics, agent_utilization, qa_coverage_stats,
    recommendations_count, flags_count, violations_count, max_severity,
    related_ticket_codes, related_agent_ids, meta
  ) VALUES (
    p_user_id, p_project_id, p_auditor_agent_id, 'daily', p_audit_date, 'completed',
    v_gov, v_flow, v_agents, v_qa,
    v_recs, v_flags, v_violations, v_max_sev,
    v_ticket_codes, v_agent_ids,
    jsonb_build_object('snapshot_ts', v_snapshot_ts::text, 'consistency_fix', 'SB-287', 'security_audit', 'SB-488')
  )
  ON CONFLICT ON CONSTRAINT process_audits_unique_daily
  DO UPDATE SET
    governance_violations = EXCLUDED.governance_violations,
    flow_metrics = EXCLUDED.flow_metrics,
    agent_utilization = EXCLUDED.agent_utilization,
    qa_coverage_stats = EXCLUDED.qa_coverage_stats,
    recommendations_count = EXCLUDED.recommendations_count,
    flags_count = EXCLUDED.flags_count,
    violations_count = EXCLUDED.violations_count,
    max_severity = EXCLUDED.max_severity,
    related_ticket_codes = EXCLUDED.related_ticket_codes,
    related_agent_ids = EXCLUDED.related_agent_ids,
    status = 'completed',
    meta = EXCLUDED.meta,
    updated_at = now()
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

-- Assertions: half B held for the two new objects; the seeded audit is quiet;
-- and a deliberately unsafe table IS reported, so the check is not vacuous.
do $$
declare
  v jsonb;
  v_seed int;
begin
  if has_table_privilege('anon', 'public.security_grant_baseline', 'SELECT')
     or has_table_privilege('authenticated', 'public.security_grant_baseline', 'SELECT')
     or has_function_privilege('anon', 'public.audit_client_role_exposure(boolean)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.audit_client_role_exposure(boolean)', 'EXECUTE') then
    raise exception 'SB-488: half B did not hold -- a new object received client-role access';
  end if;

  select count(*) into v_seed from public.security_grant_baseline;
  if v_seed < 100 then
    raise exception 'SB-488: baseline seed looks wrong (% rows)', v_seed;
  end if;

  v := public.audit_client_role_exposure(false);
  if (v->>'finding_count')::int <> 0 then
    raise exception 'SB-488: audit is not quiet on the seeded baseline: %', v;
  end if;

  -- Non-vacuity: an RLS-off table with a client grant must produce findings.
  create table public._sb488_unsafe (id int);
  grant select on public._sb488_unsafe to anon;
  v := public.audit_client_role_exposure(false);
  if (v->>'finding_count')::int < 2
     or not (v->'rls_disabled_tables') ? '_sb488_unsafe' then
    drop table public._sb488_unsafe;
    raise exception 'SB-488: audit failed to report a deliberately unsafe table: %', v;
  end if;
  drop table public._sb488_unsafe;

  raise notice 'SB-488 A: audit wired, baseline % rows, non-vacuity proven', v_seed;
end $$;
