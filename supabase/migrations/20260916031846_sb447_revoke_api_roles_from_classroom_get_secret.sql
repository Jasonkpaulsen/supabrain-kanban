-- SB-447: public.classroom_get_secret(text) is SECURITY DEFINER over vault.decrypted_secrets and
-- returns the plaintext Google Classroom credential. Its creator ran REVOKE ... FROM PUBLIC and
-- GRANT ... TO classroom_writer, but the project's default privileges had already handed
-- per-role EXECUTE to anon, authenticated and service_role — PUBLIC and those roles are
-- different grantees, so the revoke changed nothing for them (the SB-408 / SB-440 trap).
-- Verified live before this migration: anon and authenticated both received the secret.
--
-- Legitimate caller is classroom_writer over its own DSN (123 recorded calls; zero from any
-- API role). Revoke by role name and assert, rather than trust, the result.

do $$
begin
  if to_regprocedure('public.classroom_get_secret(text)') is not null then
    revoke all on function public.classroom_get_secret(text) from public, anon, authenticated;

    if has_function_privilege('anon', 'public.classroom_get_secret(text)', 'execute')
       or has_function_privilege('authenticated', 'public.classroom_get_secret(text)', 'execute') then
      raise exception 'SB-447: classroom_get_secret(text) is still executable by anon or authenticated';
    end if;
    if not has_function_privilege('classroom_writer', 'public.classroom_get_secret(text)', 'execute') then
      raise exception 'SB-447: classroom_writer lost EXECUTE on classroom_get_secret(text) — refusing to leave the MCP broken';
    end if;
  end if;
end $$;

comment on function public.classroom_get_secret(text) is
  'SB-447: returns a Vault secret in plaintext. EXECUTE is for classroom_writer (the classroom MCP DSN) only. Never grant to anon or authenticated; REVOKE FROM PUBLIC does not remove default-ACL per-role grants — revoke by role name and assert.';;
