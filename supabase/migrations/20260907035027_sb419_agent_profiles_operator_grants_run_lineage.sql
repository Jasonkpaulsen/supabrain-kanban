-- SB-419 (ADR-FAM-002): agent execution profiles, agent operator grants, and
-- explicit lineage columns on agent_runs. Structure only; access policies and
-- routines are SB-420. Idempotent through catalog checks (no
-- ADD CONSTRAINT IF NOT EXISTS, which Postgres does not support).

-- ------------------------------------------------ agent_execution_profiles
create table if not exists public.agent_execution_profiles (
  id                      uuid primary key default gen_random_uuid(),
  agent_id                uuid not null references public.agents(id) on delete cascade,
  version                 integer not null,
  display_name            text not null,
  description             text,
  role_instructions       text not null,
  guardrails              text[] not null default '{}',
  allowed_family_tools    text[] not null default '{}',
  delegation_policy       jsonb  not null default '{}'::jsonb,
  status                  text not null default 'draft',
  published_by            uuid references auth.users(id),
  published_at            timestamptz,
  source_agent_updated_at timestamptz,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);

do $$ begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.agent_execution_profiles'::regclass and conname = 'agent_execution_profiles_version_positive') then
    alter table public.agent_execution_profiles add constraint agent_execution_profiles_version_positive check (version >= 1);
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.agent_execution_profiles'::regclass and conname = 'agent_execution_profiles_status_check') then
    alter table public.agent_execution_profiles add constraint agent_execution_profiles_status_check check (status in ('draft','published','retired'));
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.agent_execution_profiles'::regclass and conname = 'agent_execution_profiles_agent_version_key') then
    alter table public.agent_execution_profiles add constraint agent_execution_profiles_agent_version_key unique (agent_id, version);
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.agent_execution_profiles'::regclass and conname = 'agent_execution_profiles_published_fields') then
    alter table public.agent_execution_profiles add constraint agent_execution_profiles_published_fields
      check (status <> 'published' or (published_by is not null and published_at is not null));
  end if;
end $$;

create unique index if not exists agent_execution_profiles_one_published_idx
  on public.agent_execution_profiles (agent_id) where status = 'published';
create index if not exists agent_execution_profiles_published_by_idx
  on public.agent_execution_profiles (published_by);

comment on table public.agent_execution_profiles is
  'SB-419 / ADR-FAM-002: curated, versioned role packets handed to an operator''s Codex session. Never holds system_prompt, mcp_tools, trigger_config, skill config, credentials or memories. At most one published row per agent.';

-- ---------------------------------------------------- agent_operator_grants
create table if not exists public.agent_operator_grants (
  id                     uuid primary key default gen_random_uuid(),
  external_connection_id uuid not null references public.external_connections(id) on delete cascade,
  principal_user_id      uuid not null references auth.users(id) on delete cascade,
  agent_id               uuid not null references public.agents(id) on delete cascade,
  root_project_id        uuid not null references public.projects(id) on delete cascade,
  scope_mode             text not null,
  permissions            text[] not null,
  status                 text not null default 'active',
  expires_at             timestamptz,
  granted_by             uuid not null references auth.users(id),
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);

do $$ begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.agent_operator_grants'::regclass and conname = 'agent_operator_grants_scope_mode_check') then
    alter table public.agent_operator_grants add constraint agent_operator_grants_scope_mode_check check (scope_mode in ('exact_project','member_descendants'));
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.agent_operator_grants'::regclass and conname = 'agent_operator_grants_permissions_check') then
    alter table public.agent_operator_grants add constraint agent_operator_grants_permissions_check
      check (permissions <@ array['view_profile','invoke','assign','delegate'] and cardinality(permissions) > 0);
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.agent_operator_grants'::regclass and conname = 'agent_operator_grants_status_check') then
    alter table public.agent_operator_grants add constraint agent_operator_grants_status_check check (status in ('active','disabled','revoked'));
  end if;
end $$;

create unique index if not exists agent_operator_grants_one_active_idx
  on public.agent_operator_grants (external_connection_id, principal_user_id, agent_id, root_project_id) where status = 'active';
create index if not exists agent_operator_grants_connection_idx on public.agent_operator_grants (external_connection_id);
create index if not exists agent_operator_grants_principal_idx  on public.agent_operator_grants (principal_user_id);
create index if not exists agent_operator_grants_agent_idx      on public.agent_operator_grants (agent_id);
create index if not exists agent_operator_grants_root_project_idx on public.agent_operator_grants (root_project_id);
create index if not exists agent_operator_grants_granted_by_idx on public.agent_operator_grants (granted_by);

comment on table public.agent_operator_grants is
  'SB-419 / ADR-FAM-002: authorizes a principal on an external connection to use an agent (view_profile|invoke|assign|delegate) within a project scope. Ownership stays on agents.user_id. One active grant per (connection, principal, agent, root_project).';

-- --------------------------------------------------- agent_runs lineage
alter table public.agent_runs add column if not exists operator_grant_id     uuid references public.agent_operator_grants(id);
alter table public.agent_runs add column if not exists oauth_client_id       text;
alter table public.agent_runs add column if not exists profile_id            uuid references public.agent_execution_profiles(id);
alter table public.agent_runs add column if not exists profile_version       integer;
alter table public.agent_runs add column if not exists parent_run_id         uuid references public.agent_runs(id);
alter table public.agent_runs add column if not exists delegated_by_agent_id uuid references public.agents(id);
alter table public.agent_runs add column if not exists trace_id              uuid;
alter table public.agent_runs add column if not exists requested_project_id  uuid references public.projects(id);

do $$
declare v_name text;
begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.agent_runs'::regclass and conname = 'agent_runs_not_self_parent') then
    alter table public.agent_runs add constraint agent_runs_not_self_parent check (parent_run_id is null or parent_run_id <> id);
  end if;
  -- status domain gains 'cancelled' (ADR-FAM-002 run lifecycle). Find the
  -- existing status CHECK by definition, since its name is not guaranteed.
  select conname into v_name from pg_constraint
   where conrelid = 'public.agent_runs'::regclass and contype = 'c'
     and pg_get_constraintdef(oid) like '%status = ANY%' and pg_get_constraintdef(oid) not like '%cancelled%';
  if v_name is not null then
    execute format('alter table public.agent_runs drop constraint %I', v_name);
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.agent_runs'::regclass and pg_get_constraintdef(oid) like '%status = ANY%') then
    alter table public.agent_runs add constraint agent_runs_status_check
      check (status in ('running','completed','failed','timeout','cancelled'));
  end if;
end $$;

create index if not exists agent_runs_operator_grant_idx   on public.agent_runs (operator_grant_id);
create index if not exists agent_runs_profile_idx          on public.agent_runs (profile_id);
create index if not exists agent_runs_parent_run_idx       on public.agent_runs (parent_run_id);
create index if not exists agent_runs_delegated_by_idx     on public.agent_runs (delegated_by_agent_id);
create index if not exists agent_runs_requested_project_idx on public.agent_runs (requested_project_id);
create index if not exists agent_runs_trace_idx            on public.agent_runs (trace_id);

-- --------------------------------------------------- RLS + privileges
alter table public.agent_execution_profiles enable row level security;
alter table public.agent_operator_grants    enable row level security;

-- Default ACL hands anon/authenticated ALL on new tables (SB-408 lesson).
revoke all on table public.agent_execution_profiles, public.agent_operator_grants from anon, public;
revoke all on table public.agent_execution_profiles, public.agent_operator_grants from authenticated;
grant select on table public.agent_execution_profiles, public.agent_operator_grants to authenticated;  -- 0 rows until SB-420 adds policies
grant all    on table public.agent_execution_profiles, public.agent_operator_grants to service_role;

do $$ begin
  if not exists (select 1 from pg_policy where polrelid = 'public.agent_execution_profiles'::regclass and polname = 'service_role_full') then
    create policy service_role_full on public.agent_execution_profiles for all to service_role using (true) with check (true);
  end if;
  if not exists (select 1 from pg_policy where polrelid = 'public.agent_operator_grants'::regclass and polname = 'service_role_full') then
    create policy service_role_full on public.agent_operator_grants for all to service_role using (true) with check (true);
  end if;
end $$;

-- --------------------------------------------------- updated_at
do $$ begin
  if not exists (select 1 from pg_trigger where tgrelid = 'public.agent_execution_profiles'::regclass and tgname = 'trg_agent_execution_profiles_updated_at') then
    create trigger trg_agent_execution_profiles_updated_at before update on public.agent_execution_profiles for each row execute function public.update_updated_at();
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'public.agent_operator_grants'::regclass and tgname = 'trg_agent_operator_grants_updated_at') then
    create trigger trg_agent_operator_grants_updated_at before update on public.agent_operator_grants for each row execute function public.update_updated_at();
  end if;
end $$;