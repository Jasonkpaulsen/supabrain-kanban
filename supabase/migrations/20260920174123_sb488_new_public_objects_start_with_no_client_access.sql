-- SB-488 (half B): a new object in public starts with no client-role access.
--
-- Why. pg_default_acl for schema public, as Supabase ships it, grants anon and
-- authenticated ALL on every new table, EXECUTE on every new function and USAGE
-- on every new sequence the moment they are created. Three consequences seen in
-- this project: meta_key_registry (SB-398) shipped anon-writable with no GRANT in
-- its migration and was caught twenty days later by an advisor lint (SB-479);
-- audit_meta_keys shipped anon-callable although its migration granted only
-- authenticated and service_role; and SB-237 had to REVOKE ... FROM PUBLIC before
-- any of its per-role revokes took effect (20260802003018).
--
-- What this changes. Only the DEFAULT for objects created from now on by the
-- postgres role. No existing grant moves: default privileges apply at creation
-- time and never retroactively. After this, a migration that adds a
-- PostgREST-facing table or RPC must say so with an explicit GRANT (and, for a
-- table, a policy), or clients get 42501 on the first call. That is the intended
-- discipline; supabase/migrations/README.md carries the convention.
--
-- Tables and sequences: a per-schema REVOKE is enough, because the grants to anon
-- and authenticated are themselves per-schema rows Supabase added.
--
-- Functions are different, and the first attempt at this migration failed on its
-- own probe because of it. PostgreSQL grants EXECUTE on every new function to
-- PUBLIC as a built-in default, and anon and authenticated inherit through
-- PUBLIC. Per-schema default privileges can only ADD to the global defaults; they
-- cannot remove a global one (ALTER DEFAULT PRIVILEGES documentation). The only
-- mechanism that removes the built-in PUBLIC EXECUTE is a GLOBAL default for the
-- role, with no IN SCHEMA clause -- so the function half of this change applies
-- to functions the postgres role creates in ANY schema, not only public. Today
-- that is public (105), extensions (49), family_gateway (2) and pgsodium (1).
-- Practical consequence: a future CREATE EXTENSION run by postgres will install
-- functions that anon and authenticated cannot call until a migration grants
-- EXECUTE on them; the fuzzystrmatch functions CLSRM-40 relies on already exist
-- and are unaffected. Stated here rather than discovered later.
--
-- Limits. This alters the postgres role's defaults only. The supabase_admin rows
-- in pg_default_acl carry the same grants and cannot be altered from postgres;
-- objects the platform itself creates keep the old behaviour. service_role is
-- untouched and keeps ALL by default. PostgREST still lists a new table in the
-- schema; it returns permission denied rather than hiding it.
--
-- Blast radius measured before running (2026-09-20): 70 tables in public, 61
-- readable by anon and 65 insertable by authenticated; 105 functions, 53
-- executable by anon. Every one of those was created under the old default.
-- None is changed here.
--
-- Rollback (restores the old default for future objects; existing ones unaffected):
--   alter default privileges for role postgres in schema public grant all on tables to anon, authenticated;
--   alter default privileges for role postgres in schema public grant execute on functions to anon, authenticated;
--   alter default privileges for role postgres grant execute on functions to public;
--   alter default privileges for role postgres in schema public grant usage, select, update on sequences to anon, authenticated;

alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public revoke execute on functions from anon, authenticated;
alter default privileges for role postgres revoke execute on functions from public;

-- Prove it on a throwaway object of each kind, created by this same role, then
-- remove the probes. The migration fails rather than records if the default is
-- not what the statements above claim.
do $$
begin
  create table public._sb488_probe_t (id int);
  create sequence public._sb488_probe_s;
  create function public._sb488_probe_f() returns int language sql as 'select 1';

  if has_table_privilege('anon', 'public._sb488_probe_t', 'SELECT')
     or has_table_privilege('authenticated', 'public._sb488_probe_t', 'INSERT') then
    raise exception 'SB-488: a new table still receives client-role privileges';
  end if;
  if has_function_privilege('anon', 'public._sb488_probe_f()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public._sb488_probe_f()', 'EXECUTE') then
    raise exception 'SB-488: a new function is still executable by client roles';
  end if;
  if has_sequence_privilege('anon', 'public._sb488_probe_s', 'USAGE')
     or has_sequence_privilege('authenticated', 'public._sb488_probe_s', 'USAGE') then
    raise exception 'SB-488: a new sequence still grants client roles USAGE';
  end if;
  if not has_table_privilege('service_role', 'public._sb488_probe_t', 'SELECT')
     or not has_function_privilege('service_role', 'public._sb488_probe_f()', 'EXECUTE') then
    raise exception 'SB-488: service_role lost a default it was meant to keep';
  end if;

  drop function public._sb488_probe_f();
  drop sequence public._sb488_probe_s;
  drop table public._sb488_probe_t;
  raise notice 'SB-488 B: new objects start with no anon/authenticated access';
end $$;
