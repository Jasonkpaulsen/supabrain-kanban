-- SB-408 trap, hit again: this project's default privileges grant EXECUTE on every new
-- public function to anon and authenticated. Those are explicit per-role grants, so the
-- "revoke all ... from public" in the previous migration did not remove them -- PUBLIC and
-- anon/authenticated are different grantees.
--
-- agent_runner_headers() returns the decrypted token, and PostgREST exposes public RPCs, so
-- for the few minutes between these two migrations the secret was retrievable with nothing
-- but the publishable anon key. Revoking explicitly, by name, and asserting the result
-- rather than trusting the REVOKE.

revoke execute on function public.agent_runner_headers() from anon, authenticated, service_role;
revoke execute on function public.agent_runner_token_matches(text) from anon, authenticated;
grant execute on function public.agent_runner_token_matches(text) to service_role;

do $$
begin
  if has_function_privilege('anon','public.agent_runner_headers()','execute')
     or has_function_privilege('authenticated','public.agent_runner_headers()','execute')
     or has_function_privilege('service_role','public.agent_runner_headers()','execute') then
    raise exception 'SB-440: agent_runner_headers() is still executable by an API role';
  end if;
  if has_function_privilege('anon','public.agent_runner_token_matches(text)','execute')
     or has_function_privilege('authenticated','public.agent_runner_token_matches(text)','execute') then
    raise exception 'SB-440: agent_runner_token_matches() is still executable by anon or authenticated';
  end if;
  if not has_function_privilege('service_role','public.agent_runner_token_matches(text)','execute') then
    raise exception 'SB-440: service_role lost EXECUTE on agent_runner_token_matches(); the Edge Function could not authenticate';
  end if;
end $$;;
