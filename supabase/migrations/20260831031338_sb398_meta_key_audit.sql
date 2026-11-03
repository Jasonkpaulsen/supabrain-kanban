
-- SB-398: a load-bearing meta key is a column that was never declared.
--
-- Every duplication in SB-388 began the same way: a value went into meta because that
-- was fast, code started branching on it, and no column was declared. The cost was not
-- theoretical — meta.archive_after_days produced SB-373 (filed claiming a feature was
-- never built, closed INVALID) and meta.dev_automation produced a recorded safety breach
-- that had not happened. Both errors were made with the schema in view.
--
-- Registry of keys that are allowed to live in JSONB, with a reason.
create table if not exists public.meta_key_registry (
  id          uuid primary key default gen_random_uuid(),
  table_name  text not null,
  key_name    text not null,
  owner       text not null,
  reason      text not null,
  registered_at timestamptz not null default now(),
  unique (table_name, key_name)
);

comment on table public.meta_key_registry is
  'SB-398: keys deliberately kept in JSONB, with an owner and a reason. Anything above the audit threshold that is NOT here is a column waiting to be declared.';

-- The audit. Reports; does not block. meta being fast is why it works — the goal is that
-- nothing load-bearing stays there UNNOTICED, not that nothing goes there.
create or replace function public.audit_meta_keys(p_min_rows int default 20)
returns table (table_name text, key_name text, row_count bigint, registered boolean, owner text)
language plpgsql
stable
set search_path to 'public'
as $fn$
begin
  return query
  with keys as (
    select 'agents'::text as tbl, k.key, count(*) as n
      from agents a, lateral jsonb_object_keys(coalesce(a.meta,'{}'::jsonb)) k(key) group by 1,2
    union all
    select 'projects', k.key, count(*)
      from projects p, lateral jsonb_object_keys(coalesce(p.meta,'{}'::jsonb)) k(key) group by 1,2
    union all
    select 'work_items', k.key, count(*)
      from work_items w, lateral jsonb_object_keys(coalesce(w.meta,'{}'::jsonb)) k(key) group by 1,2
  )
  select keys.tbl, keys.key, keys.n,
         (r.id is not null) as registered,
         coalesce(r.owner,'(unregistered)') as owner
  from keys
  left join meta_key_registry r on r.table_name = keys.tbl and r.key_name = keys.key
  where keys.n >= p_min_rows
  order by (r.id is not null), keys.n desc;
end;
$fn$;

comment on function public.audit_meta_keys(int) is
  'SB-398: list JSONB keys appearing in more than N rows, flagging those with no registered owner. Report only — never blocks a write.';

grant execute on function public.audit_meta_keys(int) to authenticated, service_role;

-- Seed the registry with the keys that survived SB-390..SB-393 and are legitimately JSONB.
insert into public.meta_key_registry (table_name, key_name, owner, reason) values
  ('agents','tier','System Architect','Small controlled vocabulary used for routing and compliance scoping; no relational use.'),
  ('agents','role','System Architect','Free-text role summary composed into the prompt; not branched on.'),
  ('agents','domain','System Architect','Domain label used for grouping; candidate for promotion if it ever gains referential meaning.'),
  ('agents','pm_assigned','System Architect','Name string, same untyped pattern as the retired reports_to. Registered as KNOWN DEBT — should become a foreign key.'),
  ('agents','qa_fixture','SupaBrain QA','Marks test scaffolding so guards and audits can exempt it.'),
  ('agents','references','System Architect','Bibliographic list; genuinely document-shaped.'),
  ('agents','memory_protocol','SupaBrain Process Engineer','Narrative protocol text; no code branches on it.'),
  ('projects','archive_after_days','Supabase Platform Engineer','Read by archive_work_items for per-project retention. Registered because it IS load-bearing — this is the key that produced SB-373.'),
  ('projects','triage_suspension','SupaBrain Process Engineer','Structured suspension record with timestamps; document-shaped.'),
  ('work_items','wip_override','SupaBrain Process Engineer','Per-ticket escape hatch read by both WIP gates. Load-bearing and deliberately kept ad hoc.'),
  ('work_items','upstream_ticket','SupaBrain Process Engineer','Derived cache of work_item_links, maintained one-way by SB-372 trigger. Registered as DERIVED — never author it by hand.'),
  ('work_items','developed_by','SupaBrain Process Engineer','Records the original author when review routing reassigns a ticket.')
on conflict (table_name, key_name) do nothing;
;
