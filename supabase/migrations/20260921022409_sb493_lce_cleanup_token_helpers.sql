-- SB-493: move the lce-cleanup bearer token out of plaintext and into Vault.
--
-- Before this, the token was a literal in two places at once: the deployed
-- function source, and cron.job.command for job 1 (lce-daily-cleanup), where it
-- sat in plaintext in the database and therefore in every backup. That is the
-- fourth instance of the SB-408 / SB-440 / SB-447 class, and it guarded a
-- function that runs with the service-role key and deletes rows from articles,
-- image_assets and image_requests plus objects from the project-assets bucket.
--
-- Same shape as public.agent_runner_token_matches / agent_runner_headers
-- (SB-440) and public.supabrain_sweep_* (SB-482): the edge function never holds
-- the token, it asks the database whether the presented value matches, and the
-- database never returns the secret.
--
-- DELIBERATELY NOT IN THIS MIGRATION: the Vault secret row itself, for the same
-- reason as 20260921011023 -- this repository is public, and a migration
-- carrying a live credential is exactly the defect being repaired here. The
-- secret 'lce_cleanup_token' was created out of band on 2026-09-21 with a value
-- generated inside the database by encode(gen_random_bytes(32),'base64'); it
-- has never been rendered to a transcript, a migration or a commit. Per
-- ADR-DL-003 that is a documented, deliberate absence rather than drift. A
-- rebuilt copy gets these functions and no secret, so the check fails closed --
-- correct, because a fresh environment must be given its own token.
--
-- The OLD literal is not reproduced here either. It is being retired, and
-- writing a dead credential into the permanent history to document its death
-- would leave it readable forever for no benefit.

create or replace function public.lce_cleanup_token_matches(p_token text)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select coalesce(
           p_token = (select s.decrypted_secret
                        from vault.decrypted_secrets s
                       where s.name = 'lce_cleanup_token'),
           false)
$function$;

create or replace function public.lce_cleanup_headers()
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
                        where s.name = 'lce_cleanup_token')
         )
$function$;

revoke all on function public.lce_cleanup_token_matches(text) from public, anon, authenticated;
revoke all on function public.lce_cleanup_headers() from public, anon, authenticated;
grant execute on function public.lce_cleanup_token_matches(text) to service_role;
grant execute on function public.lce_cleanup_headers() to service_role;

-- Assert the acceptance criteria inside the migration (ADR-DL-003 clause 5).
do $$
declare
  v_bad text;
begin
  -- 1. neither helper is reachable by a client role
  select string_agg(format('%s->%s', routine_name, grantee), ', ')
    into v_bad
    from information_schema.routine_privileges
   where specific_schema = 'public'
     and routine_name in ('lce_cleanup_token_matches','lce_cleanup_headers')
     and grantee in ('anon','authenticated','PUBLIC')
     and privilege_type = 'EXECUTE';
  if v_bad is not null then
    raise exception 'SB-493: client roles can execute the lce-cleanup auth helpers: %', v_bad;
  end if;

  -- 2. the matcher refuses a wrong token and accepts the stored one
  if public.lce_cleanup_token_matches('definitely-not-the-token') then
    raise exception 'SB-493: token matcher accepted a wrong token';
  end if;
  if not public.lce_cleanup_token_matches(
       (select s.decrypted_secret from vault.decrypted_secrets s
         where s.name = 'lce_cleanup_token')) then
    raise exception 'SB-493: token matcher rejected the stored token';
  end if;

  -- 3. the matcher cannot leak the secret through its own result type
  if pg_get_function_result(
       'public.lce_cleanup_token_matches(text)'::regprocedure) <> 'boolean' then
    raise exception 'SB-493: token matcher must return boolean and nothing else';
  end if;

  -- 4. headers carry a token of the expected shape
  if coalesce(length(public.lce_cleanup_headers() ->> 'x-token'), 0) < 32 then
    raise exception 'SB-493: lce-cleanup headers carry no usable token';
  end if;
end $$;
