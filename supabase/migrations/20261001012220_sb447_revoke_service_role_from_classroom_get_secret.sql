-- SB-447 item 2: least-privilege revoke of service_role EXECUTE on classroom_get_secret.
-- Authorized by Jason 2026-10-01. Only classroom_writer (the Classroom MCP, over its own DSN)
-- and the owner retain EXECUTE. Reversible with one GRANT.
REVOKE EXECUTE ON FUNCTION public.classroom_get_secret(text) FROM service_role;

DO $$
BEGIN
  IF has_function_privilege('service_role', 'public.classroom_get_secret(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'SB-447: service_role still holds EXECUTE after revoke';
  END IF;
  IF has_function_privilege('anon', 'public.classroom_get_secret(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'SB-447: anon holds EXECUTE (regression)';
  END IF;
  IF has_function_privilege('authenticated', 'public.classroom_get_secret(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'SB-447: authenticated holds EXECUTE (regression)';
  END IF;
  IF NOT has_function_privilege('classroom_writer', 'public.classroom_get_secret(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'SB-447: classroom_writer lost EXECUTE — Classroom MCP would break';
  END IF;
END $$;

COMMENT ON FUNCTION public.classroom_get_secret(text) IS
  'SECURITY DEFINER over vault.decrypted_secrets. EXECUTE restricted to classroom_writer only (SB-447, 2026-09-16 revoke of anon/authenticated; 2026-10-01 revoke of service_role). This project grants EXECUTE on new public functions to anon/authenticated/service_role BY ROLE NAME via default privileges — REVOKE FROM PUBLIC does NOT remove those. Always revoke by name and assert. Prior occurrences: SB-408, SB-440.';;
