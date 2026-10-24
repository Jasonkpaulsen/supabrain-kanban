-- SB-514: no function a client can execute may call pg_net.
--
-- The ticket asked for REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA net FROM anon, authenticated.
-- That cannot work from here: the grants (and schema USAGE) are PUBLIC grants made by the
-- schema owner supabase_admin, and postgres is not a member of it, so the REVOKE "succeeds" and
-- changes nothing (verified in rolled-back probes 2026-10-01 and 2026-10-23). net is not an
-- exposed schema, so a client reaches it only through a function it may execute. This closes
-- that path instead:
--
-- 1. The three SECURITY INVOKER trigger functions that client writes fire
--    (memories, skills, storage.objects) become SECURITY DEFINER, search_path still pinned to
--    ''. Each posts one fixed project URL with no secret, so running as postgres widens
--    nothing, and a client write no longer depends on the client's own net privilege. EXECUTE
--    is revoked from PUBLIC, anon and authenticated: trigger functions cannot be called directly
--    and firing does not check it (an authenticated memories insert still queues its request).
-- 2. The assertion below is the rule: no function anon or authenticated can execute calls
--    net.http_*. Event-trigger functions are skipped (no one can call them; one of the
--    platform's mentions net in its GRANT text).
--
-- Residual, documented rather than fixed: the PUBLIC grants on net (and pgsodium) are the
-- platform default; removing them needs Supabase. Behaviour is otherwise unchanged.

alter function public.trigger_memory_embedding() security definer set search_path = '';
alter function public.trigger_image_analysis() security definer set search_path = '';
alter function public.fn_trigger_skill_embedding() security definer set search_path = '';
revoke all on function public.trigger_memory_embedding(), public.trigger_image_analysis(), public.fn_trigger_skill_embedding()
  from public, anon, authenticated;

comment on function public.trigger_memory_embedding() is
  'SB-514: SECURITY DEFINER so a client insert into memories does not need its own pg_net privilege. Posts the memory id to generate-memory-embeddings.';
comment on function public.trigger_image_analysis() is
  'SB-514: SECURITY DEFINER so a client upload does not need its own pg_net privilege. Posts project-assets image paths to analyze-image.';
comment on function public.fn_trigger_skill_embedding() is
  'SB-514: SECURITY DEFINER so a client write to skills does not need its own pg_net privilege. Posts the skill id to generate-skill-embeddings.';

do $assert$
declare bad text;
begin
  select string_agg(p.oid::regprocedure::text, ', ') into bad from pg_proc p
   where p.oid in ('public.trigger_memory_embedding()'::regprocedure, 'public.trigger_image_analysis()'::regprocedure,
                   'public.fn_trigger_skill_embedding()'::regprocedure)
     and (not p.prosecdef or p.proconfig is distinct from array['search_path=""']
          or has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'));
  if bad is not null then
    raise exception 'SB-514: trigger functions not converted: %', bad;
  end if;
  select string_agg(n.nspname || '.' || p.oid::regprocedure::text, ', ') into bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname not in ('net', 'pg_catalog', 'information_schema')
     and p.prorettype <> 'event_trigger'::regtype
     and p.prosrc ~* '\mnet\.http_'
     and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'));
  if bad is not null then
    raise exception 'SB-514: client-executable functions call pg_net: %', bad;
  end if;
end
$assert$;
