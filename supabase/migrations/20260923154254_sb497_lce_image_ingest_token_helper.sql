-- SB-497: move the lce-image-ingest bearer token out of its source and into Vault.
--
-- lce-image-ingest (v1, verify_jwt=false) declares its expected token as a
-- literal constant in the deployed source. The endpoint uploads arbitrary bytes
-- into the project-assets bucket using the SERVICE ROLE key, with x-upsert:true
-- and a caller-chosen path, so whoever holds that string can write or overwrite
-- any object in that bucket.
--
-- This is the fifth instance of the SB-408 / SB-440 / SB-447 / SB-493 class and
-- the last one open. Same shape as public.agent_runner_token_matches (SB-440),
-- public.supabrain_sweep_token_matches (SB-482) and
-- public.lce_cleanup_token_matches (SB-493): the edge function never holds the
-- token, it asks the database whether the presented value matches, and the
-- database never returns the secret.
--
-- WHY THERE IS NO lce_image_ingest_headers() HERE, unlike SB-493.
-- lce-cleanup needed a header builder because cron job 1 calls it from inside
-- the database and had to stop carrying a literal in cron.job.command. Nothing
-- in this database calls lce-image-ingest: verified at migration time against
-- cron.job (11 active jobs, none referencing it) and pg_proc (no body referring
-- to it). A headers() helper would therefore be dead code whose only behaviour
-- is to return the plaintext secret in a jsonb value. Omitting it removes a way
-- to read the secret rather than leaving an unused one. The assertion block
-- below pins that absence so a later author does not "restore symmetry" with
-- SB-493 and reintroduce the reader.
--
-- DELIBERATELY NOT IN THIS MIGRATION: the Vault secret row itself, for the same
-- reason as 20260921011023 and 20260921022409 -- this repository is public, and
-- a migration carrying a live credential is exactly the defect being repaired.
-- The secret 'lce_image_ingest_token' is created out of band with a value
-- generated inside the database by encode(gen_random_bytes(32),'base64'); it is
-- never rendered to a transcript, a migration or a commit. Per ADR-DL-003 that
-- is a documented, deliberate absence rather than drift. A rebuilt copy gets
-- this function and no secret, so the check fails closed -- correct, because a
-- fresh environment must be given its own token.
--
-- The OLD literal is not reproduced here either. It is being retired, and
-- writing a dead credential into the permanent history to document its death
-- would leave it readable forever for no benefit.

create or replace function public.lce_image_ingest_token_matches(p_token text)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select coalesce(
           p_token = (select s.decrypted_secret
                        from vault.decrypted_secrets s
                       where s.name = 'lce_image_ingest_token'),
           false)
$function$;

revoke all on function public.lce_image_ingest_token_matches(text) from public, anon, authenticated;
grant execute on function public.lce_image_ingest_token_matches(text) to service_role;

-- Assert the acceptance criteria inside the migration (ADR-DL-003 clause 5).
do $$
declare
  v_bad text;
begin
  -- 1. the helper is not reachable by a client role.
  -- Named explicitly rather than relying on REVOKE ... FROM PUBLIC: the project's
  -- default privileges grant EXECUTE to anon and authenticated BY ROLE NAME, which
  -- a revoke from PUBLIC does not touch. That exact mistake is SB-408, SB-440,
  -- SB-447 and SB-493 -- four authors in a row believed a revoke had worked.
  select string_agg(format('%s->%s', routine_name, grantee), ', ')
    into v_bad
    from information_schema.routine_privileges
   where specific_schema = 'public'
     and routine_name = 'lce_image_ingest_token_matches'
     and grantee in ('anon','authenticated','PUBLIC')
     and privilege_type = 'EXECUTE';
  if v_bad is not null then
    raise exception 'SB-497: client roles can execute the ingest auth helper: %', v_bad;
  end if;

  -- 2. the matcher refuses a wrong token and accepts the stored one
  if public.lce_image_ingest_token_matches('definitely-not-the-token') then
    raise exception 'SB-497: token matcher accepted a wrong token';
  end if;
  if not public.lce_image_ingest_token_matches(
       (select s.decrypted_secret from vault.decrypted_secrets s
         where s.name = 'lce_image_ingest_token')) then
    raise exception 'SB-497: token matcher rejected the stored token';
  end if;

  -- 3. the matcher cannot leak the secret through its own result type
  if pg_get_function_result(
       'public.lce_image_ingest_token_matches(text)'::regprocedure) <> 'boolean' then
    raise exception 'SB-497: token matcher must return boolean and nothing else';
  end if;

  -- 4. NULL must not authenticate. The function is called with whatever the
  -- x-token header contained, and a missing header arrives as NULL; coalesce
  -- is what makes that false rather than NULL, and a later rewrite that drops
  -- it would turn "no header at all" into a non-false result.
  if public.lce_image_ingest_token_matches(null) is not false then
    raise exception 'SB-497: a null token must not authenticate';
  end if;

  -- 5. no headers() sibling exists (see the note above -- its absence is the
  -- design, not an omission)
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'lce_image_ingest_headers') then
    raise exception 'SB-497: lce_image_ingest_headers() exists; nothing in this database calls the function, so a secret-returning helper has no caller to justify it';
  end if;
end $$;
