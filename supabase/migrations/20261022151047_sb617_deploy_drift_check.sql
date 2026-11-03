-- SB-617: a daily, deterministic check that what is live matches main.
--
-- SB-217 asked for a deploy-drift check in the daily process audit. It was added as a
-- prompt instruction, and 0 of 111 daily audits ever ran it. This puts the check in the
-- database, on pg_cron, with no secrets: every URL it fetches is public (github.io and
-- raw.githubusercontent.com; the unauthenticated api.github.com is avoided because the
-- shared egress IP would hit its rate limit).
--
--   07:20 UTC  deploy_drift_fetch(release_ref)  queues pg_net GETs and records their ids
--   07:25 UTC  deploy_drift_evaluate()          hashes the responses and writes the result
--
-- Findings:
--   violation pages_not_live    a file on GitHub Pages differs from main, is missing, or is served but gone from main
--   violation edge_not_on_main  the latest recorded deploy of an edge function differs from main
--   flag      release_lag       a served file differs between the release branch and main
--   flag      unverifiable      a fetch failed, timed out or never answered; never read as clean
-- One activity_log row per day (artifact 'deploy_drift'), clean or not, as cron_health and
-- review_sla do. supabrain-sweep's process-engineer-daily bundle reports it.
--
-- The database cannot see which edge-function version is deployed (that needs a Management
-- API token, which is account-wide). So deploys are recorded in edge_function_deploys by
-- whoever deploys, through record_edge_function_deploy(), and the check compares that ledger
-- with main. A deploy that skips the ledger is invisible here; the supabrain-sweep README's
-- deploy procedure includes the ledger step.

create table public.edge_function_deploys (
  id          bigint generated always as identity primary key,
  slug        text not null,
  version     integer not null check (version > 0),
  ezbr_sha256 text check (ezbr_sha256 ~ '^[0-9a-f]{64}$'),
  files       jsonb not null,
  git_ref     text not null,
  deployed_at timestamptz not null,
  recorded_at timestamptz not null default now(),
  recorded_by text not null,
  note        text,
  unique (slug, version)
);
comment on table public.edge_function_deploys is
  'SB-617: ledger of edge-function deploys. files maps each deployed source path (relative to supabase/functions/<slug>/) to the sha256 of its bytes. Written through record_edge_function_deploy(); read by deploy_drift_evaluate().';
alter table public.edge_function_deploys enable row level security;
revoke all on public.edge_function_deploys from anon, authenticated;

create table public.deploy_drift_requests (
  id           bigint generated always as identity primary key,
  run_id       uuid not null,
  kind         text not null check (kind in ('pages_live', 'pages_main', 'pages_release', 'edge_main')),
  slug         text,
  path         text not null,
  url          text not null check (url ~ '^https://(jasonkpaulsen\.github\.io/supabrain-kanban/|raw\.githubusercontent\.com/Jasonkpaulsen/supabrain-kanban/refs/heads/)'),
  request_id   bigint not null,
  requested_at timestamptz not null default now()
);
create index deploy_drift_requests_run_idx on public.deploy_drift_requests (run_id);
comment on table public.deploy_drift_requests is
  'SB-617: pg_net requests queued by deploy_drift_fetch(), one row per URL, keyed by run_id.';
alter table public.deploy_drift_requests enable row level security;
revoke all on public.deploy_drift_requests from anon, authenticated;

create or replace function public.record_edge_function_deploy(
  p_slug text, p_version integer, p_ezbr_sha256 text, p_files jsonb, p_git_ref text,
  p_deployed_at timestamptz, p_recorded_by text, p_note text default null)
returns bigint
language plpgsql
set search_path = ''
as $function$
declare v_id bigint;
begin
  if p_files is null or jsonb_typeof(p_files) <> 'object' or p_files = '{}'::jsonb
     or exists (select 1 from jsonb_each_text(p_files) f where f.value !~ '^[0-9a-f]{64}$' or f.key ~ '(^/|\.\.)') then
    raise exception 'files must map relative source paths to sha256 hex digests' using errcode = '22023';
  end if;
  insert into public.edge_function_deploys (slug, version, ezbr_sha256, files, git_ref, deployed_at, recorded_by, note)
  values (p_slug, p_version, p_ezbr_sha256, p_files, p_git_ref, p_deployed_at, p_recorded_by, p_note)
  on conflict (slug, version) do update
     set ezbr_sha256 = excluded.ezbr_sha256, files = excluded.files, git_ref = excluded.git_ref,
         deployed_at = excluded.deployed_at, recorded_by = excluded.recorded_by, note = excluded.note,
         recorded_at = now()
  returning id into v_id;
  return v_id;
end
$function$;

create or replace function public.deploy_drift_fetch(p_release_ref text default null)
returns uuid
language plpgsql
set search_path = ''
as $function$
declare
  v_run  uuid := gen_random_uuid();
  pages  constant text := 'https://jasonkpaulsen.github.io/supabrain-kanban/';
  raw    constant text := 'https://raw.githubusercontent.com/Jasonkpaulsen/supabrain-kanban/refs/heads/';
  served constant text[] := array['index.html', 'jarvis-pwa.html', 'jarvis-dashboard.html', 'oauth-consent.html',
                                  'sw.js', 'config.js', 'cancel-ui.js', 'manifest.json', 'kanban-icon.svg'];
  f text; u text; d record;
begin
  if p_release_ref is not null and p_release_ref !~ '^[A-Za-z0-9._/-]+$' then
    raise exception 'release ref % is not a plain branch name', p_release_ref using errcode = '22023';
  end if;
  foreach f in array served loop
    -- The run id in the query string keeps a CDN from answering with a stale copy.
    u := pages || f || '?drift=' || v_run;
    insert into public.deploy_drift_requests (run_id, kind, path, url, request_id)
    values (v_run, 'pages_live', f, u, net.http_get(u));
    u := raw || 'main/' || f || '?drift=' || v_run;
    insert into public.deploy_drift_requests (run_id, kind, path, url, request_id)
    values (v_run, 'pages_main', f, u, net.http_get(u));
    if p_release_ref is not null and p_release_ref <> 'main' then
      u := raw || p_release_ref || '/' || f || '?drift=' || v_run;
      insert into public.deploy_drift_requests (run_id, kind, path, url, request_id)
      values (v_run, 'pages_release', f, u, net.http_get(u));
    end if;
  end loop;
  for d in select distinct on (e.slug) e.slug, e.files from public.edge_function_deploys e
            order by e.slug, e.version desc loop
    for f in select jsonb_object_keys(d.files) loop
      u := raw || 'main/supabase/functions/' || d.slug || '/' || f || '?drift=' || v_run;
      insert into public.deploy_drift_requests (run_id, kind, slug, path, url, request_id)
      values (v_run, 'edge_main', d.slug, f, u, net.http_get(u));
    end loop;
  end loop;
  return v_run;
end
$function$;

create or replace function public.deploy_drift_evaluate(p_run_id uuid default null)
returns jsonb
language plpgsql
set search_path = ''
as $function$
declare
  v_run uuid; v_at timestamptz; v_prev jsonb; v_since jsonb := '{}'::jsonb;
  v_viol jsonb := '[]'::jsonb; v_flags jsonb := '[]'::jsonb; v_lag jsonb := '[]'::jsonb; v_unv jsonb := '[]'::jsonb;
  v_summary text; v_meta jsonb; v_today uuid; r record; k text;
begin
  select q.run_id, max(q.requested_at) into v_run, v_at from public.deploy_drift_requests q
   where p_run_id is null or q.run_id = p_run_id
   group by q.run_id order by max(q.requested_at) desc limit 1;
  if v_run is null then
    raise exception 'no deploy_drift_fetch run to evaluate' using errcode = 'P0002';
  end if;

  -- "since" carries forward from the previous day's result, so a finding shows its age.
  select a.meta -> 'since' into v_prev from public.activity_log a
   where a.meta ->> 'artifact' = 'deploy_drift' and a.created_at::date < v_at::date
   order by a.created_at desc limit 1;

  for r in
    with resp as (
      select q.kind, q.slug, q.path, h.status_code, h.timed_out, h.error_msg,
             case when h.status_code = 200 then encode(pg_catalog.sha256(convert_to(h.content, 'UTF8')), 'hex') end sha,
             (h.id is null) missing
        from public.deploy_drift_requests q left join net._http_response h on h.id = q.request_id
       where q.run_id = v_run)
    select 'pages' grp, m.path, null::text slug, m.status_code main_status, m.sha main_sha, m.missing or m.timed_out is true main_lost,
           l.status_code other_status, l.sha other_sha, l.missing or l.timed_out is true other_lost, null::text ledger_sha
      from resp m join resp l on l.path = m.path and l.kind = 'pages_live' where m.kind = 'pages_main'
    union all
    select 'release', m.path, null, m.status_code, m.sha, m.missing or m.timed_out is true,
           b.status_code, b.sha, b.missing or b.timed_out is true, null
      from resp m join resp b on b.path = m.path and b.kind = 'pages_release' where m.kind = 'pages_main'
    union all
    select 'edge', m.path, m.slug, m.status_code, m.sha, m.missing or m.timed_out is true, null, null, false,
           (select e.files ->> m.path from public.edge_function_deploys e where e.slug = m.slug order by e.version desc limit 1)
      from resp m where m.kind = 'edge_main'
  loop
    k := r.grp || ':' || coalesce(r.slug || '/', '') || r.path;
    if r.main_lost or r.other_lost or coalesce(r.main_status, 0) not in (200, 404)
       or (r.grp <> 'edge' and coalesce(r.other_status, 0) not in (200, 404)) then
      v_unv := v_unv || jsonb_build_object('check', k, 'main_status', r.main_status, 'other_status', r.other_status);
    elsif r.grp = 'pages' and ((r.main_status = 200 and (r.other_status <> 200 or r.other_sha <> r.main_sha))
                              or (r.main_status = 404 and r.other_status = 200)) then
      v_since := v_since || jsonb_build_object(k, coalesce(v_prev ->> k, v_at::text));
      v_viol := v_viol || jsonb_build_object('type', 'pages_not_live', 'severity', 'high', 'file', r.path,
                                             'live_status', r.other_status, 'since', v_since ->> k);
    elsif r.grp = 'release' and (r.other_status is distinct from r.main_status or r.other_sha is distinct from r.main_sha) then
      v_since := v_since || jsonb_build_object(k, coalesce(v_prev ->> k, v_at::text));
      v_lag := v_lag || jsonb_build_object('file', r.path, 'on_main', r.main_status = 200, 'since', v_since ->> k);
    elsif r.grp = 'edge' and (r.main_status = 404 or r.main_sha <> r.ledger_sha) then
      v_since := v_since || jsonb_build_object(k, coalesce(v_prev ->> k, v_at::text));
      v_viol := v_viol || jsonb_build_object('type', 'edge_not_on_main', 'severity', 'medium', 'function', r.slug,
                                             'file', r.path, 'on_main', r.main_status = 200, 'since', v_since ->> k);
    end if;
  end loop;

  if jsonb_array_length(v_lag) > 0 then
    v_flags := v_flags || jsonb_build_object('type', 'release_lag', 'files', v_lag,
                                             'oldest_since', (select min(x ->> 'since') from jsonb_array_elements(v_lag) x));
  end if;
  if jsonb_array_length(v_unv) > 0 then
    v_flags := v_flags || jsonb_build_object('type', 'unverifiable', 'checks', v_unv);
  end if;

  v_summary := case
    when jsonb_array_length(v_viol) = 0 and jsonb_array_length(v_flags) = 0
      then 'Deploy drift: all clear — GitHub Pages serves main and every recorded edge-function deploy matches main.'
    else format('Deploy drift: %s violation(s) (%s Pages file(s) not live, %s edge-function file(s) not on main), %s release-lag file(s), %s unverifiable check(s).',
                jsonb_array_length(v_viol),
                (select count(*) from jsonb_array_elements(v_viol) x where x ->> 'type' = 'pages_not_live'),
                (select count(*) from jsonb_array_elements(v_viol) x where x ->> 'type' = 'edge_not_on_main'),
                jsonb_array_length(v_lag), jsonb_array_length(v_unv))
  end;
  v_meta := jsonb_build_object('artifact', 'deploy_drift', 'run_id', v_run, 'fetched_at', v_at,
                               'violations', v_viol, 'flags', v_flags, 'since', v_since,
                               'checked', (select count(*) from public.deploy_drift_requests q where q.run_id = v_run));

  -- One row per day: a second evaluation the same day replaces that day's row.
  select a.id into v_today from public.activity_log a
   where a.meta ->> 'artifact' = 'deploy_drift' and a.created_at::date = v_at::date
   order by a.created_at desc limit 1;
  if v_today is null then
    insert into public.activity_log (project_id, user_id, agent_name, action, target_table, summary, meta)
    values ('a07a7f3d-722f-468f-81fa-84e2c5fba704', '5ecbd44a-a3e2-4363-9133-dff3851ba0f5',
            'System', 'commented', 'deploy_drift', v_summary, v_meta);
  else
    update public.activity_log set summary = v_summary, meta = v_meta where id = v_today;
  end if;

  return jsonb_build_object('summary', v_summary, 'violations', v_viol, 'flags', v_flags, 'run_id', v_run);
end
$function$;

revoke all on function public.record_edge_function_deploy(text, integer, text, jsonb, text, timestamptz, text, text) from public, anon, authenticated;
revoke all on function public.deploy_drift_fetch(text) from public, anon, authenticated;
revoke all on function public.deploy_drift_evaluate(uuid) from public, anon, authenticated;
grant execute on function public.record_edge_function_deploy(text, integer, text, jsonb, text, timestamptz, text, text) to service_role;
grant execute on function public.deploy_drift_fetch(text) to service_role;
grant execute on function public.deploy_drift_evaluate(uuid) to service_role;

select cron.schedule('deploy-drift-fetch', '20 7 * * *',
  $job$select public.deploy_drift_fetch('claude/sb-313-execution-bqoiv1')$job$);
select cron.schedule('deploy-drift-daily', '25 7 * * *',
  $job$select public.deploy_drift_evaluate()$job$);

do $assert$
begin
  if exists (select 1 from pg_class c where c.oid in ('public.edge_function_deploys'::regclass, 'public.deploy_drift_requests'::regclass)
              and not c.relrowsecurity) then
    raise exception 'SB-617: RLS is off on a new table';
  end if;
  if has_table_privilege('anon', 'public.edge_function_deploys', 'select')
     or has_table_privilege('authenticated', 'public.edge_function_deploys', 'select')
     or has_table_privilege('anon', 'public.deploy_drift_requests', 'select')
     or has_table_privilege('authenticated', 'public.deploy_drift_requests', 'select') then
    raise exception 'SB-617: a client role can read a new table';
  end if;
  if has_function_privilege('anon', 'public.deploy_drift_fetch(text)', 'execute')
     or has_function_privilege('authenticated', 'public.deploy_drift_fetch(text)', 'execute')
     or has_function_privilege('anon', 'public.deploy_drift_evaluate(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.deploy_drift_evaluate(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.record_edge_function_deploy(text, integer, text, jsonb, text, timestamptz, text, text)', 'execute') then
    raise exception 'SB-617: a client role can run a deploy-drift function';
  end if;
  if (select count(*) from cron.job where jobname in ('deploy-drift-fetch', 'deploy-drift-daily') and active) <> 2 then
    raise exception 'SB-617: cron jobs not scheduled';
  end if;
end
$assert$;
