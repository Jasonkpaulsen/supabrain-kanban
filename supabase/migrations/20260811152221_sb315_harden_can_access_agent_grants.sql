-- SB-315 hardening: bring can_access_agent grants to parity with is_project_member/is_project_owner.
REVOKE EXECUTE ON FUNCTION public.can_access_agent(uuid, uuid) FROM PUBLIC, anon;;
