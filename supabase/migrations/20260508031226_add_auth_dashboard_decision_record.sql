
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
) VALUES (
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
);
;
