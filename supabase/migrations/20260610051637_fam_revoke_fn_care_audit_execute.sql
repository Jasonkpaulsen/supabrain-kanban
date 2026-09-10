-- fn_care_audit is a trigger function; it must not be callable via PostgREST RPC.
REVOKE EXECUTE ON FUNCTION public.fn_care_audit() FROM PUBLIC, anon, authenticated;;
