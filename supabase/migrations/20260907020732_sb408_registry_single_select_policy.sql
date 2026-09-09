-- SB-408 follow-through (TC-SB408-V7): the performance advisor flagged two
-- permissive SELECT policies per registry table (owner_manage FOR ALL +
-- principal_read_own FOR SELECT). Split owner_manage into write-only policies
-- and fold both read paths into one SELECT policy. Behaviour is identical.

drop policy owner_manage       on public.external_connections;
drop policy principal_read_own on public.external_connections;
create policy read_owner_or_principal on public.external_connections
  for select to authenticated
  using (created_by = (select auth.uid())
         or (principal_user_id = (select auth.uid()) and status in ('proposed','active')));
create policy owner_insert on public.external_connections
  for insert to authenticated with check (created_by = (select auth.uid()));
create policy owner_update on public.external_connections
  for update to authenticated
  using (created_by = (select auth.uid())) with check (created_by = (select auth.uid()));
create policy owner_delete on public.external_connections
  for delete to authenticated using (created_by = (select auth.uid()));

drop policy owner_manage       on public.external_connection_resource_grants;
drop policy principal_read_own on public.external_connection_resource_grants;
create policy read_owner_or_principal on public.external_connection_resource_grants
  for select to authenticated
  using (exists (select 1 from public.external_connections c
                 where c.id = connection_id
                   and (c.created_by = (select auth.uid())
                        or (c.principal_user_id = (select auth.uid()) and c.status in ('proposed','active')))));
create policy owner_insert on public.external_connection_resource_grants
  for insert to authenticated
  with check (exists (select 1 from public.external_connections c where c.id = connection_id and c.created_by = (select auth.uid())));
create policy owner_update on public.external_connection_resource_grants
  for update to authenticated
  using      (exists (select 1 from public.external_connections c where c.id = connection_id and c.created_by = (select auth.uid())))
  with check (exists (select 1 from public.external_connections c where c.id = connection_id and c.created_by = (select auth.uid())));
create policy owner_delete on public.external_connection_resource_grants
  for delete to authenticated
  using (exists (select 1 from public.external_connections c where c.id = connection_id and c.created_by = (select auth.uid())));