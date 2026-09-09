-- SB-429: membership-based RLS on the four core kanban tables.
-- work_items, work_item_comments, labels, work_item_labels were owner-only
-- (auth.uid() = user_id). A project_members row granted nothing on them, so
-- an editor on a shared project saw an empty board. Additive PERMISSIVE
-- policies keyed to membership; owner policies stay, except that the owner
-- INSERT/UPDATE policies now also require the project to be owned or edited
-- by the writer -- previously any authenticated user could write a row into
-- any project_id as long as user_id was their own.
-- No DELETE policy is added for members (v1 contract excludes DELETE).

create or replace function public.member_role(p_project_id uuid, p_user_id uuid)
returns text
language sql stable security definer
set search_path = public
as $$
  select pm.role from public.project_members pm
  where pm.project_id = p_project_id and pm.user_id = p_user_id
  limit 1;
$$;
comment on function public.member_role(uuid, uuid) is
  'SB-429: role of p_user_id on p_project_id (owner|editor|viewer) or NULL. SECURITY DEFINER so policies can read project_members without recursion.';

-- ---------------------------------------------------------------- work_items
create policy members_select on public.work_items
  for select to authenticated
  using (public.is_project_member(project_id, (select auth.uid())));

create policy members_insert on public.work_items
  for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and public.member_role(project_id, (select auth.uid())) in ('owner','editor')
  );

create policy members_update on public.work_items
  for update to authenticated
  using      (public.member_role(project_id, (select auth.uid())) in ('owner','editor'))
  with check (public.member_role(project_id, (select auth.uid())) in ('owner','editor'));

drop policy users_insert_own on public.work_items;
create policy users_insert_own on public.work_items
  for insert to authenticated
  with check (
    (select auth.uid()) = user_id
    and exists (select 1 from public.projects p
                where p.id = project_id and p.user_id = (select auth.uid()))
  );

drop policy users_update_own on public.work_items;
create policy users_update_own on public.work_items
  for update to authenticated
  using ((select auth.uid()) = user_id)
  with check (
    (select auth.uid()) = user_id
    and (
      exists (select 1 from public.projects p
              where p.id = project_id and p.user_id = (select auth.uid()))
      or public.member_role(project_id, (select auth.uid())) in ('owner','editor')
    )
  );

comment on policy members_select on public.work_items is 'SB-429: any project_members row on the item''s project may read it.';
comment on policy members_insert on public.work_items is 'SB-429: owner/editor members may insert into the project; user_id must be their own.';
comment on policy members_update on public.work_items is 'SB-429: owner/editor members may update; WITH CHECK stops moving a row to a non-member project.';

-- -------------------------------------------------------- work_item_comments
create policy members_select on public.work_item_comments
  for select to authenticated
  using (exists (
    select 1 from public.work_items w
    where w.id = work_item_id
      and public.is_project_member(w.project_id, (select auth.uid()))
  ));

create policy members_insert on public.work_item_comments
  for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1 from public.work_items w
      where w.id = work_item_id
        and public.member_role(w.project_id, (select auth.uid())) in ('owner','editor')
    )
  );

drop policy users_insert_own on public.work_item_comments;
create policy users_insert_own on public.work_item_comments
  for insert to authenticated
  with check (
    (select auth.uid()) = user_id
    and exists (select 1 from public.work_items w
                where w.id = work_item_id and w.user_id = (select auth.uid()))
  );

comment on policy members_select on public.work_item_comments is 'SB-429: resolves through work_items.project_id to project membership.';
comment on policy members_insert on public.work_item_comments is 'SB-429: owner/editor members may comment on items in the project; user_id must be their own. Editing stays own-comment only.';

-- -------------------------------------------------------------------- labels
create policy members_select on public.labels
  for select to authenticated
  using (project_id is not null
         and public.is_project_member(project_id, (select auth.uid())));

create policy members_insert on public.labels
  for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and project_id is not null
    and public.member_role(project_id, (select auth.uid())) in ('owner','editor')
  );

create policy members_update on public.labels
  for update to authenticated
  using      (project_id is not null and public.member_role(project_id, (select auth.uid())) in ('owner','editor'))
  with check (project_id is not null and public.member_role(project_id, (select auth.uid())) in ('owner','editor'));

drop policy users_insert_own on public.labels;
create policy users_insert_own on public.labels
  for insert to authenticated
  with check (
    (select auth.uid()) = user_id
    and (project_id is null
         or exists (select 1 from public.projects p
                    where p.id = project_id and p.user_id = (select auth.uid())))
  );

drop policy users_update_own on public.labels;
create policy users_update_own on public.labels
  for update to authenticated
  using ((select auth.uid()) = user_id)
  with check (
    (select auth.uid()) = user_id
    and (project_id is null
         or exists (select 1 from public.projects p
                    where p.id = project_id and p.user_id = (select auth.uid()))
         or public.member_role(project_id, (select auth.uid())) in ('owner','editor'))
  );

comment on policy members_select on public.labels is 'SB-429: project labels visible to members; labels with project_id NULL are personal and stay owner-only.';

-- ---------------------------------------------------------- work_item_labels
create policy members_select on public.work_item_labels
  for select to authenticated
  using (exists (
    select 1 from public.work_items w
    where w.id = work_item_id
      and public.is_project_member(w.project_id, (select auth.uid()))
  ));

create policy members_insert on public.work_item_labels
  for insert to authenticated
  with check (
    exists (
      select 1 from public.work_items w
      where w.id = work_item_id
        and public.member_role(w.project_id, (select auth.uid())) in ('owner','editor')
    )
    and exists (select 1 from public.labels l where l.id = label_id)
  );

comment on policy members_select on public.work_item_labels is 'SB-429: resolves through work_items.project_id to project membership.';
comment on policy members_insert on public.work_item_labels is 'SB-429: owner/editor members may attach a label they can see. No member DELETE: removing a label stays owner-only under the v1 no-DELETE contract.';