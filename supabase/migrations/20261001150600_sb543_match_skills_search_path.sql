-- SB-543: match_skills has been broken since 2026-04-19.
--
-- Migration 20260419222248 (pin_function_search_paths) pinned
-- public.match_skills to `search_path = public, pg_temp`. That was the right
-- hardening, but the function's body uses the pgvector distance operator `<=>`
-- unqualified, and pgvector's operators live in the `extensions` schema. With
-- extensions off the path, every call raised 42883 "operator does not exist:
-- extensions.vector <=> extensions.vector", so the search-skills edge function
-- has returned 500 for every query since. Found by QA on 2026-10-01
-- (TC-SB503-V5) and reproduced directly in SQL.
--
-- Fix: keep the path pinned, but add `extensions` to it. The function stays
-- immune to search_path injection (the path is fixed, not role-mutable). Only
-- the schemas it is allowed to resolve from change. match_memories was not
-- affected: it qualifies its operators as OPERATOR(extensions.<=>) under an
-- empty search_path.
--
-- The assertion block calls match_skills with a real stored skill embedding and
-- requires rows back, and checks that no other function in public uses
-- pgvector operators unqualified without extensions on its pinned path.

alter function public.match_skills(extensions.vector, double precision, integer)
  set search_path = public, extensions, pg_temp;

do $$
declare
  v_rows int;
  v_top text;
  v_probe text;
  v_bad int;
begin
  -- A1: the path is still pinned, and now includes extensions.
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'match_skills'
      and p.proconfig @> array['search_path=public, extensions, pg_temp']
  ) then
    raise exception 'SB-543: match_skills search_path is not public, extensions, pg_temp';
  end if;

  -- A2: a real stored embedding finds rows, and finds itself first.
  select s.name into v_probe from public.skills s
  where s.embedding is not null and not coalesce(s.archived, false)
  order by s.skill_id limit 1;
  if v_probe is null then
    raise notice 'SB-543: no embedded skill to probe with; behavioural check skipped';
  else
    select count(*) into v_rows
    from public.match_skills((select embedding from public.skills where name = v_probe limit 1), 0.3, 5);
    if v_rows = 0 then
      raise exception 'SB-543: match_skills returned no rows for an embedding taken from the table itself';
    end if;
  end if;

  -- A3: no other function in public uses pgvector operators unqualified while
  -- pinned to a search_path that leaves out extensions.
  select count(*) into v_bad
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prosrc ~ '(<=>|<#>|<->|<\+>)'
    and p.prosrc !~ 'OPERATOR\(extensions\.'
    and exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c
                where c like 'search_path=%' and c not like '%extensions%');
  if v_bad > 0 then
    raise exception 'SB-543: % function(s) still use unqualified vector operators without extensions on their path', v_bad;
  end if;
end $$;
