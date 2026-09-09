-- SB-430: replace the single FOR ALL `*_access` policy on seven family tables
-- with role-gated per-command policies (the school_assignments shape).
--   SELECT: own row, any member of child_project, or project owner
--   INSERT: own row AND (owner|editor member or project owner)
--   UPDATE: USING own row / editor member / project owner; WITH CHECK editor member or project owner
--   DELETE: project owner only (spec default; Jason approved without choosing the alternative)
-- family_events.child_project_id is nullable: personal events (NULL) stay owner-only.
do $$
declare
  t record;
  uid  text := '(select auth.uid())';
  owner_of text;   -- project owner predicate
  member text; editor text; own text;
begin
  for t in select * from (values
      ('act','activities'), ('bl','behavioral_logs'), ('cp','care_plans'), ('fe','family_events'),
      ('he','health_events'), ('hp','health_providers'), ('med','medications')) v(prefix, tbl)
  loop
    owner_of := format('exists (select 1 from public.projects pr where pr.id = child_project_id and pr.user_id = %s)', uid);
    member   := format('public.is_project_member(child_project_id, %s)', uid);
    editor   := format('public.member_role(child_project_id, %s) in (''owner'',''editor'')', uid);
    own      := format('user_id = %s', uid);

    execute format('drop policy if exists %I on public.%I', t.prefix || '_access', t.tbl);
    execute format('drop policy if exists %I on public.%I', t.prefix || '_select', t.tbl);
    execute format('drop policy if exists %I on public.%I', t.prefix || '_insert', t.tbl);
    execute format('drop policy if exists %I on public.%I', t.prefix || '_update', t.tbl);
    execute format('drop policy if exists %I on public.%I', t.prefix || '_delete', t.tbl);

    if t.tbl = 'family_events' then
      execute format('create policy %I on public.%I for select to authenticated using (%s or (child_project_id is not null and (%s or %s)))',
        t.prefix || '_select', t.tbl, own, member, owner_of);
      execute format('create policy %I on public.%I for insert to authenticated with check (%s and (child_project_id is null or %s or %s))',
        t.prefix || '_insert', t.tbl, own, editor, owner_of);
      execute format('create policy %I on public.%I for update to authenticated using (%s or (child_project_id is not null and (%s or %s))) with check ((child_project_id is null and %s) or (child_project_id is not null and (%s or %s)))',
        t.prefix || '_update', t.tbl, own, editor, owner_of, own, editor, owner_of);
      execute format('create policy %I on public.%I for delete to authenticated using ((child_project_id is null and %s) or (child_project_id is not null and %s))',
        t.prefix || '_delete', t.tbl, own, owner_of);
    else
      execute format('create policy %I on public.%I for select to authenticated using (%s or %s or %s)',
        t.prefix || '_select', t.tbl, own, member, owner_of);
      execute format('create policy %I on public.%I for insert to authenticated with check (%s and (%s or %s))',
        t.prefix || '_insert', t.tbl, own, editor, owner_of);
      execute format('create policy %I on public.%I for update to authenticated using (%s or %s or %s) with check (%s or %s)',
        t.prefix || '_update', t.tbl, own, editor, owner_of, editor, owner_of);
      execute format('create policy %I on public.%I for delete to authenticated using (%s)',
        t.prefix || '_delete', t.tbl, owner_of);
    end if;

    execute format('comment on policy %I on public.%I is %L', t.prefix || '_delete', t.tbl,
      'SB-430: DELETE is project-owner only (v1 no-DELETE contract for members). Reverse by adding the editor predicate if Jason chooses option (a).');
  end loop;
end $$;