-- GUARD ADDED 2026-09-20 (SB-439). The body below is otherwise unchanged.
--
-- This migration seeds a row. Replayed into an empty database it failed on a
-- foreign key: decisions.project_id references projects(id) and
-- decisions.user_id references auth.users(id), and a branch is created with
-- no data by design. It was the first migration to stop the SB-439 replay
-- after the object repairs landed (38 of 266).
--
-- Rewritten VALUES -> SELECT ... WHERE, following the pattern this codebase
-- already established in 20260911044338_sb442_family_pm_agent_project_travel_planning:
-- a data migration must not assume production rows exist. On an empty database
-- the guards are false, the SELECT yields no rows, and the migration is a no-op.
--
-- Proven a no-op against production before committing: run in a rolled-back
-- transaction, it inserted 0 rows, because the NOT EXISTS clause sees the row
-- this migration created in May. The added NOT EXISTS also makes it idempotent,
-- which the original gen_random_uuid() VALUES form was not.
INSERT INTO public.decisions (
  id,
  project_id,
  user_id,
  title,
  decision,
  reasoning,
  alternatives_considered,
  tags,
  meta,
  archived,
  created_at,
  updated_at
)
SELECT
  gen_random_uuid(),
  '219c49e4-9953-41a8-a806-629e7dab00a5',
  '5ecbd44a-a3e2-4363-9133-dff3851ba0f5',
  'Add Supabase Auth login to Job Pipeline Dashboard',
  'Replaced anonymous API access (anon key) with proper Supabase Auth email/password login flow in job-pipeline-dashboard.html. Dashboard now requires authentication, uses session tokens for all REST API calls, auto-refreshes tokens, persists sessions across reloads, and includes a Sign Out button. This was required after enabling RLS and removing permissive anonymous policies on job_applications.',
  'The security audit identified that job_applications had overly permissive anon SELECT and UPDATE policies (anon_select_jobs, anon_update_jobs) allowing unauthenticated access to all rows. After dropping those policies and properly scoping access to authenticated users via auth.uid() = user_id, the dashboard relied on the anon key and stopped returning data. Rather than using the service_role key (which bypasses RLS and is a security risk if the file is ever shared), we implemented proper Supabase Auth so the dashboard authenticates as the user and the existing RLS policies (users_select_own, users_update_own) work correctly.',
  ARRAY['Use service_role key (quick but insecure for any shared context)', 'Add API Gateway with custom auth (over-engineered for single-user dashboard)', 'Keep anon policies and accept the security risk (unacceptable)'],
  ARRAY['security', 'auth', 'rls', 'dashboard', 'job-pipeline'],
  '{"affected_files": ["job-pipeline-dashboard.html"], "related_migrations": ["enable_rls_employer_details", "drop_anon_policies_job_applications", "revoke_public_execute_security_definer"], "supabase_advisory": "rls_disabled_in_public"}'::jsonb,
  false,
  now(),
  now()
WHERE EXISTS (
        SELECT 1 FROM public.projects p
         WHERE p.id = '219c49e4-9953-41a8-a806-629e7dab00a5')
  AND EXISTS (
        SELECT 1 FROM auth.users u
         WHERE u.id = '5ecbd44a-a3e2-4363-9133-dff3851ba0f5')
  AND NOT EXISTS (
        SELECT 1 FROM public.decisions d
         WHERE d.title = 'Add Supabase Auth login to Job Pipeline Dashboard'
           AND d.project_id = '219c49e4-9953-41a8-a806-629e7dab00a5');
