
-- SB-399: projects.depth and projects.path claimed to describe the hierarchy
-- while disagreeing with it. 22 projects have parent_project_id; depth was > 0
-- on 8 and path was set on 7, so every board grouping by depth saw a flat list
-- of 41 top-level projects regardless of the foreign keys.
--
-- Step 1 audit: no repo file, view or function reads either column. So the
-- SB-388-consistent answer applies — derive, don't store.
create or replace view public.project_tree
with (security_invoker = true) as
with recursive t as (
  select p.id, p.name, p.parent_project_id, p.project_key, p.domain, p.archived,
         0 as depth,
         array[p.name] as name_path,
         p.name as path_label
    from public.projects p
   where p.parent_project_id is null
  union all
  select c.id, c.name, c.parent_project_id, c.project_key, c.domain, c.archived,
         t.depth + 1,
         t.name_path || c.name,
         t.path_label || ' / ' || c.name
    from public.projects c
    join t on t.id = c.parent_project_id
)
select id as project_id, name, parent_project_id, project_key, domain, archived,
       depth, name_path, path_label
  from t;

comment on view public.project_tree is
  'Derived project hierarchy from projects.parent_project_id (SB-399). Replaces the stored depth and path columns, which were maintained on roughly a third of rows.';

grant select on public.project_tree to anon, authenticated, service_role;

alter table public.projects drop column if exists depth;
alter table public.projects drop column if exists path;
;
