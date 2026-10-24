-- SB-420 (ADR-FAM-002): the operator execution path.
-- The authorization core lives in family_gateway, which is not in PostgREST's
-- exposed schemas and carries no USAGE grant to anon or authenticated. The seven
-- entry points must live in public because PostgREST only exposes public; they are
-- thin SECURITY DEFINER wrappers that delegate every decision to the private core.
-- Raw agent tables are already denied to the external client by SB-409's
-- oauth_client_deny; this migration adds the only sanctioned way through.

create schema if not exists family_gateway;
revoke all on schema family_gateway from public;

-- ---------------------------------------------------------------- private core
create or replace function family_gateway.is_descendant_or_self(p_project_id uuid, p_root uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  with recursive t(id, depth) as (
    select p_root, 0
    union all
    select c.id, t.depth + 1 from public.projects c join t on c.parent_project_id = t.id where t.depth < 10
  )
  select exists (select 1 from t where t.id = p_project_id);
$$;

create or replace function family_gateway.authorize(p_agent_id uuid, p_project_id uuid, p_permission text)
returns table (grant_id uuid, profile_id uuid, profile_version integer, connection_id uuid, client_id text)
language plpgsql stable security definer set search_path = ''
as $fn$
declare
  v_uid uuid := (select auth.uid());
  v_client text := public.oauth_client_id();
  v_conn uuid;
  v_grant public.agent_operator_grants%rowtype;
  v_prof_id uuid; v_prof_ver integer;
begin
  if v_uid is null then
    raise exception 'SB-420: no authenticated user' using errcode = '42501';
  end if;
  if v_client is null then
    raise exception 'SB-420: family agent tools are reachable only through the external client session' using errcode = '42501';
  end if;

  select c.id into v_conn from public.external_connections c
   where c.principal_user_id = v_uid and c.oauth_client_id = v_client
     and c.status = 'active' and (c.expires_at is null or c.expires_at > now());
  if v_conn is null then
    raise exception 'SB-420: no active connection for this principal and client' using errcode = '42501';
  end if;

  select g.* into v_grant from public.agent_operator_grants g
   where g.external_connection_id = v_conn
     and g.principal_user_id = v_uid
     and g.agent_id = p_agent_id
     and g.status = 'active'
     and (g.expires_at is null or g.expires_at > now())
     and p_permission = any (g.permissions)
     and ( (g.scope_mode = 'exact_project' and g.root_project_id = p_project_id)
        or (g.scope_mode = 'member_descendants' and family_gateway.is_descendant_or_self(p_project_id, g.root_project_id)) )
   limit 1;
  if v_grant.id is null then
    raise exception 'SB-420: no active % grant for this agent in that project', p_permission using errcode = '42501';
  end if;

  if not exists (select 1 from public.project_members pm where pm.user_id = v_uid and pm.project_id = p_project_id) then
    raise exception 'SB-420: not a member of the requested project' using errcode = '42501';
  end if;
  if not exists (select 1 from public.agent_projects ap where ap.agent_id = p_agent_id and ap.project_id = p_project_id) then
    raise exception 'SB-420: agent is not assigned to the requested project' using errcode = '42501';
  end if;
  if not exists (select 1 from public.agents a where a.id = p_agent_id and a.status = 'active') then
    raise exception 'SB-420: agent is not active' using errcode = '42501';
  end if;

  select p.id, p.version into v_prof_id, v_prof_ver from public.agent_execution_profiles p
   where p.agent_id = p_agent_id and p.status = 'published' limit 1;
  if v_prof_id is null then
    raise exception 'SB-420: no published execution profile for this agent' using errcode = '42501';
  end if;

  return query select v_grant.id, v_prof_id, v_prof_ver, v_conn, v_client;
end $fn$;

comment on function family_gateway.authorize(uuid, uuid, text) is
  'SB-420 / ADR-FAM-002: the whole visibility-and-invocation predicate, re-derived on every call. Raises 42501 on the first failing condition. Takes no user id — identity is auth.uid() only.';

-- ------------------------------------------------------------- entry points
create or replace function public.list_family_agents(p_project_id uuid default null)
returns table (agent_id uuid, agent_name text, project_id uuid, project_name text,
               profile_id uuid, profile_version integer, display_name text, description text,
               permissions text[], scope_mode text, can_delegate boolean)
language sql stable security definer set search_path = ''
as $$
  select a.id, a.name, pr.id, pr.name, p.id, p.version, p.display_name, p.description,
         g.permissions, g.scope_mode, ('delegate' = any (g.permissions))
    from public.agent_operator_grants g
    join public.external_connections c
      on c.id = g.external_connection_id
     and c.principal_user_id = (select auth.uid())
     and c.oauth_client_id = public.oauth_client_id()
     and c.status = 'active' and (c.expires_at is null or c.expires_at > now())
    join public.agents a on a.id = g.agent_id and a.status = 'active'
    join public.agent_execution_profiles p on p.agent_id = a.id and p.status = 'published'
    join public.agent_projects ap on ap.agent_id = a.id
    join public.projects pr on pr.id = ap.project_id
    join public.project_members pm on pm.project_id = ap.project_id and pm.user_id = (select auth.uid())
   where (select auth.uid()) is not null
     and public.oauth_client_id() is not null
     and g.principal_user_id = (select auth.uid())
     and g.status = 'active' and (g.expires_at is null or g.expires_at > now())
     and 'view_profile' = any (g.permissions)
     and ( (g.scope_mode = 'exact_project' and g.root_project_id = ap.project_id)
        or (g.scope_mode = 'member_descendants' and family_gateway.is_descendant_or_self(ap.project_id, g.root_project_id)) )
     and (p_project_id is null or ap.project_id = p_project_id);
$$;

create or replace function public.get_family_agent_profile(p_agent_id uuid, p_project_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_auth record; v_p public.agent_execution_profiles%rowtype; v_name text;
begin
  select * into v_auth from family_gateway.authorize(p_agent_id, p_project_id, 'view_profile');
  select * into v_p from public.agent_execution_profiles where id = v_auth.profile_id;
  select a.name into v_name from public.agents a where a.id = p_agent_id;
  return jsonb_build_object(
    'agent_id', p_agent_id, 'agent_name', v_name, 'project_id', p_project_id,
    'profile_id', v_p.id, 'profile_version', v_p.version,
    'display_name', v_p.display_name, 'description', v_p.description,
    'role_instructions', v_p.role_instructions,
    'guardrails', to_jsonb(v_p.guardrails),
    'allowed_family_tools', to_jsonb(v_p.allowed_family_tools),
    'delegation_targets', coalesce(v_p.delegation_policy -> 'allowed_children', '[]'::jsonb));
end $$;

create or replace function public.start_family_agent_session(
  p_agent_id uuid, p_project_id uuid, p_purpose text, p_work_item_id uuid default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_auth record; v_run uuid; v_trace uuid := gen_random_uuid(); v_limit int; v_running int;
begin
  select * into v_auth from family_gateway.authorize(p_agent_id, p_project_id, 'invoke');
  if p_work_item_id is not null
     and not exists (select 1 from public.work_items w where w.id = p_work_item_id and w.project_id = p_project_id) then
    raise exception 'SB-420: work item is not in the requested project' using errcode = '42501';
  end if;
  select coalesce(a.max_concurrent_tasks, 5) into v_limit from public.agents a where a.id = p_agent_id;
  select count(*) into v_running from public.agent_runs r
   where r.agent_id = p_agent_id and r.user_id = (select auth.uid()) and r.status = 'running';
  if v_running >= v_limit then
    raise exception 'SB-420: % sessions already running for this agent (limit %)', v_running, v_limit using errcode = '55006';
  end if;
  insert into public.agent_runs (user_id, agent_id, work_item_id, project_id, requested_project_id,
      started_at, status, trigger_type, operator_grant_id, oauth_client_id, profile_id, profile_version, trace_id, run_metadata)
  values ((select auth.uid()), p_agent_id, p_work_item_id, p_project_id, p_project_id,
      now(), 'running', 'manual', v_auth.grant_id, v_auth.client_id, v_auth.profile_id, v_auth.profile_version, v_trace,
      jsonb_build_object('purpose', p_purpose, 'via', 'family_gateway'))
  returning id into v_run;
  return public.get_family_agent_profile(p_agent_id, p_project_id)
         || jsonb_build_object('run_id', v_run, 'trace_id', v_trace, 'purpose', p_purpose);
end $$;

create or replace function public.delegate_family_agent_session(
  p_parent_run_id uuid, p_child_agent_id uuid, p_purpose text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_parent public.agent_runs%rowtype; v_pauth record; v_cauth record; v_children jsonb; v_run uuid;
begin
  select * into v_parent from public.agent_runs r
   where r.id = p_parent_run_id and r.user_id = (select auth.uid()) and r.status = 'running';
  if v_parent.id is null then
    raise exception 'SB-420: parent run not found, not yours, or not running' using errcode = '42501';
  end if;
  select * into v_pauth from family_gateway.authorize(v_parent.agent_id, v_parent.requested_project_id, 'delegate');
  select p.delegation_policy -> 'allowed_children' into v_children
    from public.agent_execution_profiles p where p.id = v_pauth.profile_id;
  if not (coalesce(v_children, '[]'::jsonb) ? p_child_agent_id::text) then
    raise exception 'SB-420: that agent is not a delegation target of the parent role' using errcode = '42501';
  end if;
  select * into v_cauth from family_gateway.authorize(p_child_agent_id, v_parent.requested_project_id, 'invoke');
  insert into public.agent_runs (user_id, agent_id, work_item_id, project_id, requested_project_id,
      started_at, status, trigger_type, operator_grant_id, oauth_client_id, profile_id, profile_version,
      trace_id, parent_run_id, delegated_by_agent_id, run_metadata)
  values ((select auth.uid()), p_child_agent_id, v_parent.work_item_id, v_parent.requested_project_id, v_parent.requested_project_id,
      now(), 'running', 'chain', v_cauth.grant_id, v_cauth.client_id, v_cauth.profile_id, v_cauth.profile_version,
      v_parent.trace_id, p_parent_run_id, v_parent.agent_id, jsonb_build_object('purpose', p_purpose, 'via', 'family_gateway'))
  returning id into v_run;
  return public.get_family_agent_profile(p_child_agent_id, v_parent.requested_project_id)
         || jsonb_build_object('run_id', v_run, 'trace_id', v_parent.trace_id, 'parent_run_id', p_parent_run_id, 'purpose', p_purpose);
end $$;

create or replace function public.complete_family_agent_session(
  p_run_id uuid, p_result_summary text default null, p_status text default 'completed')
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_run public.agent_runs%rowtype;
begin
  if p_status not in ('completed','failed','cancelled') then
    raise exception 'SB-420: status must be completed, failed or cancelled' using errcode = '22023';
  end if;
  update public.agent_runs r
     set status = p_status, finished_at = now(), result_summary = coalesce(p_result_summary, r.result_summary)
   where r.id = p_run_id and r.user_id = (select auth.uid())
     and r.status = 'running' and r.operator_grant_id is not null
  returning * into v_run;
  if v_run.id is null then
    raise exception 'SB-420: run not found, not yours, or not running' using errcode = '42501';
  end if;
  return jsonb_build_object('run_id', v_run.id, 'status', v_run.status, 'finished_at', v_run.finished_at);
end $$;

create or replace function public.list_my_family_agent_sessions(p_project_id uuid default null)
returns table (run_id uuid, agent_id uuid, agent_name text, project_id uuid, status text,
               started_at timestamptz, finished_at timestamptz, parent_run_id uuid, trace_id uuid, profile_version integer)
language sql stable security definer set search_path = ''
as $$
  select r.id, r.agent_id, a.name, r.requested_project_id, r.status, r.started_at, r.finished_at,
         r.parent_run_id, r.trace_id, r.profile_version
    from public.agent_runs r join public.agents a on a.id = r.agent_id
   where (select auth.uid()) is not null
     and r.user_id = (select auth.uid())
     and r.operator_grant_id is not null
     and (p_project_id is null or r.requested_project_id = p_project_id)
   order by r.started_at desc;
$$;

create or replace function public.assign_family_agent_to_work_item(p_agent_id uuid, p_work_item_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_proj uuid; v_auth record;
begin
  select w.project_id into v_proj from public.work_items w where w.id = p_work_item_id;
  if v_proj is null then
    raise exception 'SB-420: work item not found' using errcode = '42501';
  end if;
  select * into v_auth from family_gateway.authorize(p_agent_id, v_proj, 'assign');
  if coalesce(public.member_role(v_proj, (select auth.uid())), '') not in ('owner','editor') then
    raise exception 'SB-420: assignment requires owner or editor membership' using errcode = '42501';
  end if;
  update public.work_items set assigned_agent_id = p_agent_id, updated_at = now() where id = p_work_item_id;
  return jsonb_build_object('work_item_id', p_work_item_id, 'agent_id', p_agent_id, 'project_id', v_proj);
end $$;

-- --------------------------------------------------------- owner-path fixes
-- SB-429 recorded this interaction: the owner could no longer assign an agent to
-- an item a member created, because the check was user_id only.
create or replace function public.assign_agent_to_item(p_item_id uuid, p_agent_id uuid)
returns void language plpgsql set search_path to ''
as $$
declare v_uid uuid := (select auth.uid()); v_proj uuid;
begin
  select w.project_id into v_proj from public.work_items w
   where w.id = p_item_id
     and (w.user_id = v_uid or coalesce(public.member_role(w.project_id, v_uid), '') in ('owner','editor'));
  if v_proj is null then
    raise exception 'Not authorized to modify this item';
  end if;
  if p_agent_id is not null and not exists (
       select 1 from public.agents where id = p_agent_id and user_id = v_uid) then
    raise exception 'Agent not found or not authorized';
  end if;
  update public.work_items set assigned_agent_id = p_agent_id, updated_at = now() where id = p_item_id;
end $$;

-- The p_user_id parameter let any signed-in caller ask whether SOMEONE ELSE can
-- reach an agent. Bound to auth.uid() when a JWT is present; service_role and
-- internal callers (auth.uid() null) are unchanged, and the agents /
-- agent_skills policies that pass auth.uid() keep working.
create or replace function public.can_access_agent(p_agent_id uuid, p_user_id uuid)
returns boolean language sql stable security definer set search_path to 'public'
as $$
  select case
    when (select auth.uid()) is not null and p_user_id is distinct from (select auth.uid()) then false
    else exists (select 1 from agent_projects ap
                  where ap.agent_id = p_agent_id and is_project_member(ap.project_id, p_user_id))
  end;
$$;

-- ------------------------------------------------------------------- grants
revoke execute on function
  public.list_family_agents(uuid), public.get_family_agent_profile(uuid, uuid),
  public.start_family_agent_session(uuid, uuid, text, uuid),
  public.delegate_family_agent_session(uuid, uuid, text),
  public.complete_family_agent_session(uuid, text, text),
  public.list_my_family_agent_sessions(uuid),
  public.assign_family_agent_to_work_item(uuid, uuid)
from public, anon;

grant execute on function
  public.list_family_agents(uuid), public.get_family_agent_profile(uuid, uuid),
  public.start_family_agent_session(uuid, uuid, text, uuid),
  public.delegate_family_agent_session(uuid, uuid, text),
  public.complete_family_agent_session(uuid, text, text),
  public.list_my_family_agent_sessions(uuid),
  public.assign_family_agent_to_work_item(uuid, uuid)
to authenticated;

revoke execute on function family_gateway.authorize(uuid, uuid, text),
                           family_gateway.is_descendant_or_self(uuid, uuid)
from public, anon, authenticated;;
