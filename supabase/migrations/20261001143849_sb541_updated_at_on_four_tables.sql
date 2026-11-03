-- SB-541: every UPDATE on agent_projects, agent_skills, labels and
-- project_skills failed with 42703 "record new has no field updated_at".
--
-- All four tables carry trigger_update_updated_at (BEFORE UPDATE, FOR EACH ROW,
-- public.update_updated_at(), which sets NEW.updated_at = now()), but none of
-- them has an updated_at column. So every UPDATE raised, and agents fell back to
-- DELETE + INSERT, which loses the row's history and its assigned_at unless the
-- caller copied it across by hand. Found 2026-10-01 by the System Architect
-- while changing agent_skills.config for SB-530.
--
-- Fix (option A on the ticket): give the four tables the column the trigger
-- expects, matching the convention every other table here follows. It is added
-- with DEFAULT now(), so existing rows get this migration's time as their
-- baseline. updated_at was never tracked on these tables before, so there is no
-- older value to recover, and the default avoids an UPDATE pass over the rows.
-- Existing callers are unaffected: an INSERT that does not name the column
-- takes the default. trg_regen_delegation_map on agent_projects fires on INSERT
-- and DELETE only, so adding a column does not fire it.
--
-- The assertion block checks the schema, that no table anywhere still runs the
-- trigger without the column, and that an UPDATE on a real row of each table
-- now succeeds. Each UPDATE runs in a savepoint that is rolled back, so applying
-- this migration changes the schema and no row.

alter table public.agent_projects add column if not exists updated_at timestamptz not null default now();
alter table public.agent_skills   add column if not exists updated_at timestamptz not null default now();
alter table public.labels         add column if not exists updated_at timestamptz not null default now();
alter table public.project_skills add column if not exists updated_at timestamptz not null default now();

do $$
declare
  t text;
  v_missing int;
  v_ts timestamptz;
begin
  -- A1: the column exists, is NOT NULL and defaults to now(), on all four.
  foreach t in array array['agent_projects', 'agent_skills', 'labels', 'project_skills'] loop
    if not exists (
      select 1 from information_schema.columns
      where table_schema = 'public' and table_name = t and column_name = 'updated_at'
        and data_type = 'timestamp with time zone' and is_nullable = 'NO'
        and column_default = 'now()'
    ) then
      raise exception 'SB-541: %.updated_at is missing or not timestamptz NOT NULL DEFAULT now()', t;
    end if;
  end loop;

  -- A2: no table in public still runs update_updated_at() without the column.
  select count(*) into v_missing
  from pg_trigger tg
  join pg_class c on c.oid = tg.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
  join pg_proc p on p.oid = tg.tgfoid
  where n.nspname = 'public' and not tg.tgisinternal and p.proname = 'update_updated_at'
    and not exists (
      select 1 from information_schema.columns ic
      where ic.table_schema = 'public' and ic.table_name = c.relname and ic.column_name = 'updated_at');
  if v_missing > 0 then
    raise exception 'SB-541: % table(s) still run update_updated_at() without an updated_at column', v_missing;
  end if;

  -- A3: an UPDATE on a real row of each table succeeds and stamps updated_at.
  -- Each runs in a savepoint rolled back by raising 'rb'. A table with no rows
  -- is skipped rather than failed.
  foreach t in array array['agent_projects', 'agent_skills', 'labels', 'project_skills'] loop
    v_ts := null;
    begin
      execute format(
        'with one as (select ctid from public.%I limit 1)
         update public.%I x set updated_at = updated_at from one where x.ctid = one.ctid
         returning x.updated_at', t, t) into v_ts;
      raise exception 'rb';
    exception when raise_exception then
      if sqlerrm <> 'rb' then raise; end if;
    end;
    if v_ts is not null and v_ts <> now() then
      raise exception 'SB-541: UPDATE on % did not stamp updated_at with the transaction time', t;
    end if;
  end loop;
end $$;
