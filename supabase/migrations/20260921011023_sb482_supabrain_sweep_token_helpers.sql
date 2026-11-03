-- SB-482: Vault-backed auth helpers for the supabrain-sweep edge function.
--
-- Exact counterpart of public.agent_runner_token_matches / agent_runner_headers
-- (SB-440). The edge function never holds the token: it asks the database
-- whether the presented value matches, and the database never returns the
-- secret. pg_cron, if it ever calls this endpoint, builds its headers through
-- supabrain_sweep_headers() rather than carrying a literal in cron.job.command.
--
-- DELIBERATELY NOT IN THIS MIGRATION: the Vault secret row itself.
-- Creating it here would put a live credential into supabase_migrations
-- .schema_migrations and into a PUBLIC GitHub repository, which is precisely
-- the SB-440 failure. The secret 'supabrain_sweep_token' was created out of
-- band on 2026-09-21 by vault.create_secret() with a value generated inside
-- the database (encode(gen_random_bytes(32),'base64')); it has never been
-- rendered to a transcript, a migration or a commit. Per ADR-DL-003 that
-- out-of-band object is a documented, deliberate absence rather than drift --
-- the same treatment 20260531010318 gave the classroom_writer policies -- so
-- the SB-490 coverage scan will keep flagging it and the reason stays visible.
-- A rebuilt copy of this database will therefore have these two functions and
-- no secret, and the token check will fail closed (false), which is correct:
-- a fresh environment must be given its own token, not inherit production's.

create or replace function public.supabrain_sweep_token_matches(p_token text)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select coalesce(
           p_token = (select s.decrypted_secret
                        from vault.decrypted_secrets s
                       where s.name = 'supabrain_sweep_token'),
           false)
$function$;

create or replace function public.supabrain_sweep_headers()
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
  select jsonb_build_object(
           'Content-Type', 'application/json',
           'x-token', (select s.decrypted_secret
                         from vault.decrypted_secrets s
                        where s.name = 'supabrain_sweep_token')
         )
$function$;

revoke all on function public.supabrain_sweep_token_matches(text) from public, anon, authenticated;
revoke all on function public.supabrain_sweep_headers() from public, anon, authenticated;
grant execute on function public.supabrain_sweep_token_matches(text) to service_role;
grant execute on function public.supabrain_sweep_headers() to service_role;

-- Assert the acceptance criteria inside the migration (ADR-DL-003 clause 5),
-- so it cannot half-apply and still record as applied.
do $$
declare
  v_bad text;
begin
  -- 1. neither helper is reachable by a client role
  select string_agg(format('%s->%s', routine_name, grantee), ', ')
    into v_bad
    from information_schema.routine_privileges
   where specific_schema = 'public'
     and routine_name in ('supabrain_sweep_token_matches','supabrain_sweep_headers')
     and grantee in ('anon','authenticated','PUBLIC')
     and privilege_type = 'EXECUTE';
  if v_bad is not null then
    raise exception 'SB-482: client roles can execute the sweep auth helpers: %', v_bad;
  end if;

  -- 2. the matcher refuses a wrong token and accepts the real one
  if public.supabrain_sweep_token_matches('definitely-not-the-token') then
    raise exception 'SB-482: token matcher accepted a wrong token';
  end if;
  if not public.supabrain_sweep_token_matches(
       (select s.decrypted_secret from vault.decrypted_secrets s
         where s.name = 'supabrain_sweep_token')) then
    raise exception 'SB-482: token matcher rejected the stored token';
  end if;

  -- 3. the matcher never leaks the secret through its own result type
  if pg_get_function_result(
       'public.supabrain_sweep_token_matches(text)'::regprocedure) <> 'boolean' then
    raise exception 'SB-482: token matcher must return boolean and nothing else';
  end if;

  -- 4. headers carry a token of the expected shape
  if coalesce(length(public.supabrain_sweep_headers() ->> 'x-token'), 0) < 32 then
    raise exception 'SB-482: sweep headers carry no usable token';
  end if;
end $$;
