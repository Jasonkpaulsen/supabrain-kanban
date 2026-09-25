-- SB-235: Revoke default PUBLIC execute, then re-grant to specific roles
-- PostgreSQL grants EXECUTE to PUBLIC by default; revoking from anon/authenticated
-- alone doesn't help because they inherit from PUBLIC.

-- articles_touch: authenticated users need this (article timestamp updates)
REVOKE EXECUTE ON FUNCTION public.articles_touch() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.articles_touch() TO authenticated;

-- is_project_member / is_project_owner: used in RLS policies, 
-- authenticated role needs EXECUTE for RLS evaluation
REVOKE EXECUTE ON FUNCTION public.is_project_member(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_project_member(uuid, uuid) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.is_project_owner(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_project_owner(uuid, uuid) TO authenticated;

-- audit_approval_reversal: trigger function, only called by postgres/table owner
REVOKE EXECUTE ON FUNCTION public.audit_approval_reversal() FROM PUBLIC;

-- watch_ functions: cron-only, called by postgres
REVOKE EXECUTE ON FUNCTION public.watch_cip154_dispatch149() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.watch_cip165_dispatch166() FROM PUBLIC;;
