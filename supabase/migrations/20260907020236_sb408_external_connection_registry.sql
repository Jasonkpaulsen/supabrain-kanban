-- SB-408: control-plane registry for end-user MCP connections (ADR-API-002).
-- Three tables: a server-side resource catalog (what MAY be granted, with
-- field deny lists), external_connections (one per principal+OAuth client),
-- and external_connection_resource_grants (what a connection IS granted).
-- The catalog bounds the grants: a grant may not name a resource outside the
-- catalog nor an operation the catalog does not allow. No DELETE is allowed
-- for any v1 resource. Project scope is NOT stored here; it is derived from
-- public.project_members at call time.

-- ------------------------------------------------------------ catalog
create table public.external_resource_catalog (
  resource_name       text primary key,
  table_schema        text not null default 'public',
  table_name          text not null,
  allowed_operations  text[] not null,
  denied_fields       text[] not null default '{}'::text[],
  notes               text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint external_resource_catalog_ops_domain
    check (allowed_operations <@ array['select','insert','update','delete']::text[]
           and cardinality(allowed_operations) > 0),
  constraint external_resource_catalog_table_unique unique (table_schema, table_name)
);
comment on table public.external_resource_catalog is
  'SB-408: server-side catalog of resources an external (end-user MCP) connection may be granted. Each resource maps to a hard-coded handler; denied_fields are never returned even when the table is granted.';

-- -------------------------------------------------------- connections
create table public.external_connections (
  id                 uuid primary key default gen_random_uuid(),
  name               text not null,
  principal_user_id  uuid references auth.users(id) on delete cascade,
  oauth_client_id    text,
  status             text not null default 'proposed',
  created_by         uuid not null references auth.users(id),
  expires_at         timestamptz,
  meta               jsonb not null default '{}'::jsonb,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint external_connections_status_check
    check (status in ('proposed','active','disabled','revoked')),
  constraint external_connections_active_requires_principal_and_client
    check (status <> 'active' or (principal_user_id is not null and oauth_client_id is not null)),
  constraint external_connections_oauth_client_id_key unique (oauth_client_id)
);
comment on table public.external_connections is
  'SB-408: one row per end-user MCP connection (principal + pre-registered OAuth client). Cannot be active without principal_user_id and oauth_client_id.';

create index external_connections_principal_idx on public.external_connections (principal_user_id);
create index external_connections_created_by_idx on public.external_connections (created_by);
create index external_connections_status_idx    on public.external_connections (status);

-- ------------------------------------------------------------- grants
create table public.external_connection_resource_grants (
  id             uuid primary key default gen_random_uuid(),
  connection_id  uuid not null references public.external_connections(id) on delete cascade,
  resource_name  text not null references public.external_resource_catalog(resource_name) on update cascade,
  operations     text[] not null,
  created_by     uuid not null references auth.users(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint external_connection_resource_grants_ops_domain
    check (operations <@ array['select','insert','update','delete']::text[]
           and cardinality(operations) > 0),
  constraint external_connection_resource_grants_conn_resource_key unique (connection_id, resource_name)
);
comment on table public.external_connection_resource_grants is
  'SB-408: resource/action grants for one connection. Bounded by external_resource_catalog via trg_external_grant_within_catalog.';

create index external_connection_resource_grants_connection_idx on public.external_connection_resource_grants (connection_id);
create index external_connection_resource_grants_resource_idx   on public.external_connection_resource_grants (resource_name);
create index external_connection_resource_grants_created_by_idx on public.external_connection_resource_grants (created_by);

-- catalog bounds the grants
create or replace function public.external_grant_within_catalog()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_allowed text[];
begin
  select allowed_operations into v_allowed
  from public.external_resource_catalog where resource_name = new.resource_name;
  if v_allowed is null then
    raise exception 'SB-408: resource % is not in external_resource_catalog', new.resource_name
      using errcode = '23503';
  end if;
  if not (new.operations <@ v_allowed) then
    raise exception 'SB-408: operations % exceed the catalog allowance % for resource %',
      new.operations, v_allowed, new.resource_name
      using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger trg_external_grant_within_catalog
  before insert or update on public.external_connection_resource_grants
  for each row execute function public.external_grant_within_catalog();

create trigger trg_external_connections_updated_at
  before update on public.external_connections
  for each row execute function public.update_updated_at();
create trigger trg_external_connection_resource_grants_updated_at
  before update on public.external_connection_resource_grants
  for each row execute function public.update_updated_at();
create trigger trg_external_resource_catalog_updated_at
  before update on public.external_resource_catalog
  for each row execute function public.update_updated_at();

-- ---------------------------------------------------------------- RLS
alter table public.external_resource_catalog            enable row level security;
alter table public.external_connections                 enable row level security;
alter table public.external_connection_resource_grants  enable row level security;

create policy service_role_full on public.external_resource_catalog
  for all to service_role using (true) with check (true);
create policy authenticated_read on public.external_resource_catalog
  for select to authenticated using (true);

create policy service_role_full on public.external_connections
  for all to service_role using (true) with check (true);
create policy owner_manage on public.external_connections
  for all to authenticated
  using (created_by = (select auth.uid()))
  with check (created_by = (select auth.uid()));
create policy principal_read_own on public.external_connections
  for select to authenticated
  using (principal_user_id = (select auth.uid()) and status in ('proposed','active'));

create policy service_role_full on public.external_connection_resource_grants
  for all to service_role using (true) with check (true);
create policy owner_manage on public.external_connection_resource_grants
  for all to authenticated
  using (exists (select 1 from public.external_connections c
                 where c.id = connection_id and c.created_by = (select auth.uid())))
  with check (exists (select 1 from public.external_connections c
                      where c.id = connection_id and c.created_by = (select auth.uid())));
create policy principal_read_own on public.external_connection_resource_grants
  for select to authenticated
  using (exists (select 1 from public.external_connections c
                 where c.id = connection_id
                   and c.principal_user_id = (select auth.uid())
                   and c.status in ('proposed','active')));

-- ------------------------------------------- privileges (distinct from RLS)
-- Default ACLs in this project hand anon full table privileges; take them back.
revoke all on table public.external_resource_catalog,
                    public.external_connections,
                    public.external_connection_resource_grants from anon, public;
grant select on table public.external_resource_catalog to authenticated;
grant select, insert, update, delete on table public.external_connections,
                                           public.external_connection_resource_grants to authenticated;
grant all on table public.external_resource_catalog,
                   public.external_connections,
                   public.external_connection_resource_grants to service_role;

-- SB-429 hygiene found by the security advisor: member_role() was callable by anon.
revoke execute on function public.member_role(uuid, uuid) from anon, public;

-- --------------------------------------------------------------- seed
insert into public.external_resource_catalog (resource_name, table_name, allowed_operations, denied_fields, notes) values
  ('projects',            'projects',            array['select'],                   '{}', 'v1 core read'),
  ('project_members',     'project_members',     array['select'],                   '{}', 'v1 core read'),
  ('work_items',          'work_items',          array['select','insert','update'], '{}', 'v1 core write, no delete'),
  ('work_item_comments',  'work_item_comments',  array['select','insert','update'], '{}', 'v1 core write, no delete'),
  ('labels',              'labels',              array['select','insert','update'], '{}', 'v1 core write, no delete'),
  ('work_item_labels',    'work_item_labels',    array['select','insert','update'], '{}', 'v1 core write, no delete'),
  ('activities',          'activities',          array['select','insert','update'], '{}', 'family/medical, no delete'),
  ('behavioral_logs',     'behavioral_logs',     array['select','insert','update'], '{}', 'family/medical, no delete'),
  ('care_plans',          'care_plans',          array['select','insert','update'], '{}', 'family/medical, no delete'),
  ('family_events',       'family_events',       array['select','insert','update'], '{}', 'family, no delete'),
  ('health_events',       'health_events',       array['select','insert','update'], '{}', 'family/medical, no delete'),
  ('health_providers',    'health_providers',    array['select','insert','update'], array['portal_secret_ref'], 'family/medical, no delete; portal_secret_ref and any future secret-like column must be added here before exposure'),
  ('medications',         'medications',         array['select','insert','update'], '{}', 'family/medical, no delete; regimen writes need explicit confirmation (ADR-API-002)'),
  ('school_assignments',  'school_assignments',  array['select','insert','update'], '{}', 'family, no delete'),
  ('care_audit_log',      'care_audit_log',      array['select'],                   '{}', 'audit read only');

insert into public.external_connections (id, name, principal_user_id, oauth_client_id, status, created_by, meta)
values ('c0de0000-0000-4000-a000-000000000408',
        'Mandy — Codex Family Data MCP (v1)',
        '0dd94a9f-1890-48b0-9e4f-a4bbfff949f0',
        null, 'proposed',
        '5ecbd44a-a3e2-4363-9133-dff3851ba0f5',
        jsonb_build_object('ticket','SB-408','epic','SB-406','adr','ADR-API-002',
                           'activation_blocked_on','SB-410 registers the OAuth client and writes oauth_client_id'));

insert into public.external_connection_resource_grants (connection_id, resource_name, operations, created_by)
select 'c0de0000-0000-4000-a000-000000000408', resource_name, allowed_operations, '5ecbd44a-a3e2-4363-9133-dff3851ba0f5'
from public.external_resource_catalog;