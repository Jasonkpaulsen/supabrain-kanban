-- SB-433 part 2 (regression from SB-409)
--
-- Granting EXECUTE on public.oauth_client_id() to PUBLIC was necessary but not
-- sufficient. The body called auth.jwt(), and resolving that name needs USAGE on
-- schema auth, which bespoke login roles such as classroom_writer do not have:
--   42501: permission denied for schema auth
--   QUERY:  select nullif(auth.jwt() ->> 'client_id', '')
--   CONTEXT: SQL function "oauth_client_id" during startup
--            PL/pgSQL function oauth_client_guard_immutable() line 4 at IF
--
-- trg_oauth_client_immutable fires on UPDATE only, which is why the classroom
-- sync's upsert failed on its update path while plain inserts went through.
--
-- Two ways out: grant USAGE on schema auth to every direct-DSN role, or remove the
-- dependency. auth.jwt() is nothing but a read of two session settings —
--   coalesce(nullif(current_setting('request.jwt.claim',  true), ''),
--            nullif(current_setting('request.jwt.claims', true), ''))::jsonb
-- so inlining it is exactly equivalent and needs no privilege at all. That is
-- preferred over SECURITY DEFINER: it keeps the function SECURITY INVOKER, adds no
-- cross-schema grant, and leaves the 119 SB-409 RESTRICTIVE policies unchanged in
-- meaning. A caller with no JWT still gets null, so the guard early-returns.

create or replace function public.oauth_client_id()
returns text
language sql
stable
set search_path to ''
as $fn$
  select nullif(
           coalesce(
             nullif(current_setting('request.jwt.claim',  true), ''),
             nullif(current_setting('request.jwt.claims', true), '')
           )::jsonb ->> 'client_id',
           ''
         )
$fn$;

grant execute on function public.oauth_client_id() to public;;
