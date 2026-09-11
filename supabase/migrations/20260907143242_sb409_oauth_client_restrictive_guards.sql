-- SB-409 (ADR-API-002): make the external OAuth client default-deny at the
-- database boundary. A session is an "external client session" when the JWT
-- carries a client_id claim. Direct browser sessions (no claim) are untouched:
-- every policy below is RESTRICTIVE and its first disjunct is "client_id is null".
--   * 15 catalog tables: SELECT/INSERT/UPDATE allowed only when an active
--     connection for (auth.uid(), client_id) holds a grant for that resource and
--     operation AND the row is inside a member project (writes: owner|editor);
--     DELETE denied for the client outright.
--   * every other RLS-enabled public table: denied for the client.
--   * BEFORE UPDATE trigger on the 15: identity/routing/secret fields immutable
--     through the client.
-- Idempotent through catalog checks.

create or replace function public.oauth_client_id()
returns text language sql stable
as $$ select nullif(auth.jwt() ->> 'client_id', '') $$;
comment on function public.oauth_client_id() is 'SB-409: client_id claim of the current JWT, or NULL for a direct session.';

create or replace function public.external_grant_allows(p_resource text, p_operation text)
returns boolean language sql stable security definer set search_path = public
as $$
  select public.oauth_client_id() is null
      or exists (
        select 1
        from public.external_connections c
        join public.external_connection_resource_grants g on g.connection_id = c.id
        where c.principal_user_id = (select auth.uid())
          and c.oauth_client_id = public.oauth_client_id()
          and c.status = 'active'
          and (c.expires_at is null or c.expires_at > now())
          and g.resource_name = p_resource
          and p_operation = any (g.operations))
$$;
comment on function public.external_grant_allows(text, text) is 'SB-409: true for direct sessions; for an external client session, true only if the active connection for (auth.uid(), client_id) grants p_operation on p_resource.';
revoke execute on function public.oauth_client_id() from anon, public;
revoke execute on function public.external_grant_allows(text, text) from anon, public;
grant  execute on function public.oauth_client_id() to authenticated, service_role;
grant  execute on function public.external_grant_allows(text, text) to authenticated, service_role;

create or replace function public.oauth_client_guard_immutable()
returns trigger language plpgsql set search_path = public
as $$
declare k text; nj jsonb := to_jsonb(new); oj jsonb := to_jsonb(old);
begin
  if public.oauth_client_id() is null then return new; end if;
  foreach k in array array['id','user_id','created_by','actor_id','project_id','child_project_id','work_item_id','label_id','portal_secret_ref'] loop
    if (nj ? k) and (nj -> k) is distinct from (oj -> k) then
      raise exception 'SB-409: % is not writable through the external client', k using errcode = '42501';
    end if;
  end loop;
  return new;
end $$;

do $$
declare
  t record; cid text := '(select public.oauth_client_id())'; uid text := '(select auth.uid())';
  sel text; wr text;
begin
  -- resource, table, member-read predicate, editor-write predicate
  for t in select * from (values
    ('projects','projects',
       format('public.is_project_member(id, %s)', '(select auth.uid())'),
       format('public.member_role(id, %s) in (''owner'',''editor'')', '(select auth.uid())')),
    ('project_members','project_members', 'user_id = (select auth.uid())', 'false'),
    ('work_items','work_items',
       'public.is_project_member(project_id, (select auth.uid()))',
       'public.member_role(project_id, (select auth.uid())) in (''owner'',''editor'')'),
    ('labels','labels',
       'project_id is not null and public.is_project_member(project_id, (select auth.uid()))',
       'project_id is not null and public.member_role(project_id, (select auth.uid())) in (''owner'',''editor'')'),
    ('work_item_comments','work_item_comments',
       'exists (select 1 from public.work_items w where w.id = work_item_id and public.is_project_member(w.project_id, (select auth.uid())))',
       'exists (select 1 from public.work_items w where w.id = work_item_id and public.member_role(w.project_id, (select auth.uid())) in (''owner'',''editor''))'),
    ('work_item_labels','work_item_labels',
       'exists (select 1 from public.work_items w where w.id = work_item_id and public.is_project_member(w.project_id, (select auth.uid())))',
       'exists (select 1 from public.work_items w where w.id = work_item_id and public.member_role(w.project_id, (select auth.uid())) in (''owner'',''editor''))'),
    ('activities','activities',       'public.is_project_member(child_project_id, (select auth.uid()))', 'public.member_role(child_project_id, (select auth.uid())) in (''owner'',''editor'')'),
    ('behavioral_logs','behavioral_logs', 'public.is_project_member(child_project_id, (select auth.uid()))', 'public.member_role(child_project_id, (select auth.uid())) in (''owner'',''editor'')'),
    ('care_plans','care_plans',       'public.is_project_member(child_project_id, (select auth.uid()))', 'public.member_role(child_project_id, (select auth.uid())) in (''owner'',''editor'')'),
    ('family_events','family_events', 'child_project_id is not null and public.is_project_member(child_project_id, (select auth.uid()))', 'child_project_id is not null and public.member_role(child_project_id, (select auth.uid())) in (''owner'',''editor'')'),
    ('health_events','health_events', 'public.is_project_member(child_project_id, (select auth.uid()))', 'public.member_role(child_project_id, (select auth.uid())) in (''owner'',''editor'')'),
    ('health_providers','health_providers', 'public.is_project_member(child_project_id, (select auth.uid()))', 'public.member_role(child_project_id, (select auth.uid())) in (''owner'',''editor'')'),
    ('medications','medications',     'public.is_project_member(child_project_id, (select auth.uid()))', 'public.member_role(child_project_id, (select auth.uid())) in (''owner'',''editor'')'),
    ('school_assignments','school_assignments', 'public.is_project_member(child_project_id, (select auth.uid()))', 'public.member_role(child_project_id, (select auth.uid())) in (''owner'',''editor'')'),
    ('care_audit_log','care_audit_log', 'child_project_id is not null and public.is_project_member(child_project_id, (select auth.uid()))', 'false')
  ) v(res, tbl, member_pred, editor_pred)
  loop
    if not exists (select 1 from pg_policy where polrelid = ('public.' || t.tbl)::regclass and polname = 'oauth_client_select') then
      execute format('create policy oauth_client_select on public.%I as restrictive for select to authenticated using (%s is null or ((select public.external_grant_allows(%L, ''select'')) and (%s)))', t.tbl, cid, t.res, t.member_pred);
    end if;
    if not exists (select 1 from pg_policy where polrelid = ('public.' || t.tbl)::regclass and polname = 'oauth_client_insert') then
      execute format('create policy oauth_client_insert on public.%I as restrictive for insert to authenticated with check (%s is null or ((select public.external_grant_allows(%L, ''insert'')) and (%s)))', t.tbl, cid, t.res, t.editor_pred);
    end if;
    if not exists (select 1 from pg_policy where polrelid = ('public.' || t.tbl)::regclass and polname = 'oauth_client_update') then
      execute format('create policy oauth_client_update on public.%I as restrictive for update to authenticated using (%s is null or ((select public.external_grant_allows(%L, ''update'')) and (%s))) with check (%s is null or ((select public.external_grant_allows(%L, ''update'')) and (%s)))', t.tbl, cid, t.res, t.editor_pred, cid, t.res, t.editor_pred);
    end if;
    if not exists (select 1 from pg_policy where polrelid = ('public.' || t.tbl)::regclass and polname = 'oauth_client_delete') then
      execute format('create policy oauth_client_delete on public.%I as restrictive for delete to authenticated using (%s is null)', t.tbl, cid);
    end if;
    if not exists (select 1 from pg_trigger where tgrelid = ('public.' || t.tbl)::regclass and tgname = 'trg_oauth_client_immutable') then
      execute format('create trigger trg_oauth_client_immutable before update on public.%I for each row execute function public.oauth_client_guard_immutable()', t.tbl);
    end if;
  end loop;

  -- registry tables: the client may read its own connection and grants, never write
  if not exists (select 1 from pg_policy where polrelid = 'public.external_connections'::regclass and polname = 'oauth_client_select') then
    execute format('create policy oauth_client_select on public.external_connections as restrictive for select to authenticated using (%s is null or (principal_user_id = %s and oauth_client_id = %s))', cid, uid, cid);
  end if;
  if not exists (select 1 from pg_policy where polrelid = 'public.external_connection_resource_grants'::regclass and polname = 'oauth_client_select') then
    execute format('create policy oauth_client_select on public.external_connection_resource_grants as restrictive for select to authenticated using (%s is null or exists (select 1 from public.external_connections c where c.id = connection_id and c.principal_user_id = %s and c.oauth_client_id = %s))', cid, uid, cid);
  end if;
  for t in select unnest(array['external_connections','external_connection_resource_grants','external_resource_catalog']) as tbl loop
    if not exists (select 1 from pg_policy where polrelid = ('public.' || t.tbl)::regclass and polname = 'oauth_client_deny_insert') then
      execute format('create policy oauth_client_deny_insert on public.%I as restrictive for insert to authenticated with check (%s is null)', t.tbl, cid);
      execute format('create policy oauth_client_deny_update on public.%I as restrictive for update to authenticated using (%s is null) with check (%s is null)', t.tbl, cid, cid);
      execute format('create policy oauth_client_deny_delete on public.%I as restrictive for delete to authenticated using (%s is null)', t.tbl, cid);
    end if;
  end loop;

  -- every other RLS-enabled public table: the client gets nothing
  for t in
    select tablename as tbl from pg_tables
    where schemaname = 'public' and rowsecurity
      and tablename not in ('projects','project_members','work_items','labels','work_item_comments','work_item_labels',
                            'activities','behavioral_logs','care_plans','family_events','health_events','health_providers',
                            'medications','school_assignments','care_audit_log',
                            'external_connections','external_connection_resource_grants','external_resource_catalog')
  loop
    if not exists (select 1 from pg_policy where polrelid = ('public.' || t.tbl)::regclass and polname = 'oauth_client_deny') then
      execute format('create policy oauth_client_deny on public.%I as restrictive for all to authenticated using (%s is null) with check (%s is null)', t.tbl, cid, cid);
    end if;
  end loop;
end $$;;
