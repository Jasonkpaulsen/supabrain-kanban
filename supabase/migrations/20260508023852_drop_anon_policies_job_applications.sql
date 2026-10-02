
-- Drop the overly permissive anonymous UPDATE policy
DROP POLICY IF EXISTS "anon_update_jobs" ON public.job_applications;

-- Drop the anonymous SELECT policy (all rows readable by anyone)
DROP POLICY IF EXISTS "anon_select_jobs" ON public.job_applications;
;
