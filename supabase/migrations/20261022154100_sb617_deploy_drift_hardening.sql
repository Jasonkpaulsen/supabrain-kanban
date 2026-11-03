-- SB-617 follow-up: harden the deploy-drift check (independent verifier, minors 1-4, 6, 7).
--
-- 1  A finding's "since" now survives a day on which it was unverifiable, and unverifiable
--    checks carry their own age, so a fetch that keeps failing shows how long it has.
-- 2  A served file that is missing on main, on Pages and on the release branch is flagged
--    not_found (the served list is fixed in the function; a rename must not pass silently).
-- 3  Evaluation is serialised with an advisory lock, and a run fetched more than 5 hours ago
--    is refused (pg_net keeps responses 6 hours), so a late re-run cannot overwrite a good
--    day with an all-unverifiable one.
-- 4  When every release-branch file is 404 the branch is gone (merged, renamed): one
--    release_ref_missing flag instead of a permanent release_lag on every file.
-- 6  release_ref and slugs are validated: no "..", no leading or doubled slash.
-- 7  Days and "since" are computed in UTC whatever the session time zone, and stored as
--    ISO-8601 text, so min() over them is chronological.
--
-- Not changed, by design: the check compares the ledger with main in one direction only. A
-- function or file that exists on main but was never recorded as deployed raises nothing,
-- because listing main needs the GitHub API, which this check avoids. Signatures and grants
-- are unchanged.

create or replace function public.record_edge_function_deploy(
  p_slug text, p_version integer, p_ezbr_sha256 text, p_files jsonb, p_git_ref text,
  p_deployed_at timestamptz, p_recorded_by text, p_note text default null)
returns bigint
language plpgsql
set search_path = ''
as $function$
declare v_id bigint;
begin
  if p_slug is null or p_slug !~ '^[a-z0-9][a-z0-9_-]{0,63}$' then
    raise exception 'slug % is not a function name', p_slug using errcode = '22023';
  end if;
  if p_files is null or jsonb_typeof(p_files) <> 'object' or p_files = '{}'::jsonb
     or exists (select 1 from jsonb_each_text(p_files) f
                 where f.value !~ '^[0-9a-f]{64}$' or f.key !~ '^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$' or f.key ~ '\.\.') then
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
  if p_release_ref is not null and (p_release_ref !~ '^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$' or p_release_ref ~ '\.\.') then
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
            where e.slug ~ '^[a-z0-9][a-z0-9_-]{0,63}$'
            order by e.slug, e.version desc loop
    for f in select k from jsonb_object_keys(d.files) k where k !~ '\.\.' loop
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
  iso constant text := 'YYYY-MM-DD"T"HH24:MI:SS"Z"';
  v_run uuid; v_at timestamptz; v_day date; v_prev jsonb; v_since jsonb := '{}'::jsonb; s text;
  v_viol jsonb := '[]'::jsonb; v_flags jsonb := '[]'::jsonb; v_lag jsonb := '[]'::jsonb; v_unv jsonb := '[]'::jsonb;
  v_nf jsonb := '[]'::jsonb; v_rel_total int; v_rel_404 int; v_rel_ref text; v_rel_gone boolean;
  v_summary text; v_meta jsonb; v_today uuid; r record; k text;
begin
  -- Two evaluations at once would both decide "no row today" and both insert.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('public.deploy_drift_evaluate'));

  select q.run_id, max(q.requested_at) into v_run, v_at from public.deploy_drift_requests q
   where p_run_id is null or q.run_id = p_run_id
   group by q.run_id order by max(q.requested_at) desc limit 1;
  if v_run is null then
    raise exception 'no deploy_drift_fetch run to evaluate' using errcode = 'P0002';
  end if;
  if v_at < now() - interval '5 hours' then
    raise exception 'run % was fetched at %; pg_net keeps responses for 6 hours, so fetch again', v_run, v_at
      using errcode = '55000';
  end if;
  v_day := (v_at at time zone 'UTC')::date;

  -- "since" carries forward from the previous day's result, so a finding shows its age.
  select a.meta -> 'since' into v_prev from public.activity_log a
   where a.meta ->> 'artifact' = 'deploy_drift' and (a.created_at at time zone 'UTC')::date < v_day
   order by a.created_at desc limit 1;

  select count(*), count(*) filter (where h.status_code = 404), min(substring(q.url from '/refs/heads/(.*)/[^/]*$'))
    into v_rel_total, v_rel_404, v_rel_ref
    from public.deploy_drift_requests q left join net._http_response h on h.id = q.request_id
   where q.run_id = v_run and q.kind = 'pages_release';
  v_rel_gone := v_rel_total > 0 and v_rel_404 = v_rel_total;

  for r in
    with resp as (
      select q.kind, q.slug, q.path, h.status_code, h.timed_out,
             case when h.status_code = 200 then encode(pg_catalog.sha256(convert_to(h.content, 'UTF8')), 'hex') end sha,
             (h.id is null) missing
        from public.deploy_drift_requests q left join net._http_response h on h.id = q.request_id
       where q.run_id = v_run)
    select 'pages' grp, m.path, null::text slug, m.status_code main_status, m.sha main_sha, m.missing or m.timed_out is true main_lost,
           l.status_code other_status, l.sha other_sha, l.missing or l.timed_out is true other_lost, null::text ledger_sha,
           (select b.status_code from resp b where b.path = m.path and b.kind = 'pages_release') rel_status
      from resp m join resp l on l.path = m.path and l.kind = 'pages_live' where m.kind = 'pages_main'
    union all
    select 'release', m.path, null, m.status_code, m.sha, m.missing or m.timed_out is true,
           b.status_code, b.sha, b.missing or b.timed_out is true, null, null
      from resp m join resp b on b.path = m.path and b.kind = 'pages_release' where m.kind = 'pages_main'
    union all
    select 'edge', m.path, m.slug, m.status_code, m.sha, m.missing or m.timed_out is true, null, null, false,
           (select e.files ->> m.path from public.edge_function_deploys e where e.slug = m.slug order by e.version desc limit 1), null
      from resp m where m.kind = 'edge_main'
  loop
    k := r.grp || ':' || coalesce(r.slug || '/', '') || r.path;
    s := to_char(coalesce((v_prev ->> k)::timestamptz, v_at) at time zone 'UTC', iso);
    if r.main_lost or r.other_lost or coalesce(r.main_status, 0) not in (200, 404)
       or (r.grp <> 'edge' and coalesce(r.other_status, 0) not in (200, 404)) then
      -- Keep the age: an unverifiable day must not restart a finding's clock.
      v_since := v_since || jsonb_build_object(k, s);
      v_unv := v_unv || jsonb_build_object('check', k, 'main_status', r.main_status, 'other_status', r.other_status, 'since', s);
    elsif r.grp = 'pages' and ((r.main_status = 200 and (r.other_status <> 200 or r.other_sha <> r.main_sha))
                              or (r.main_status = 404 and r.other_status = 200)) then
      v_since := v_since || jsonb_build_object(k, s);
      v_viol := v_viol || jsonb_build_object('type', 'pages_not_live', 'severity', 'high', 'file', r.path,
                                             'live_status', r.other_status, 'since', s);
    elsif r.grp = 'pages' and r.main_status = 404 and r.other_status = 404 and coalesce(r.rel_status, 404) = 404 then
      v_since := v_since || jsonb_build_object(k, s);
      v_nf := v_nf || jsonb_build_object('file', r.path, 'since', s);
    elsif r.grp = 'release' and not v_rel_gone
          and (r.other_status is distinct from r.main_status or r.other_sha is distinct from r.main_sha) then
      v_since := v_since || jsonb_build_object(k, s);
      v_lag := v_lag || jsonb_build_object('file', r.path, 'on_main', r.main_status = 200, 'since', s);
    elsif r.grp = 'edge' and (r.main_status = 404 or r.main_sha <> r.ledger_sha) then
      v_since := v_since || jsonb_build_object(k, s);
      v_viol := v_viol || jsonb_build_object('type', 'edge_not_on_main', 'severity', 'medium', 'function', r.slug,
                                             'file', r.path, 'on_main', r.main_status = 200, 'since', s);
    end if;
  end loop;

  if jsonb_array_length(v_lag) > 0 then
    v_flags := v_flags || jsonb_build_object('type', 'release_lag', 'ref', v_rel_ref, 'files', v_lag,
                                             'oldest_since', (select min(x ->> 'since') from jsonb_array_elements(v_lag) x));
  end if;
  if v_rel_gone then
    k := 'release_ref_missing:' || coalesce(v_rel_ref, '?');
    s := to_char(coalesce((v_prev ->> k)::timestamptz, v_at) at time zone 'UTC', iso);
    v_since := v_since || jsonb_build_object(k, s);
    v_flags := v_flags || jsonb_build_object('type', 'release_ref_missing', 'ref', v_rel_ref, 'since', s,
                                             'note', 'every file is 404 on this branch; update the deploy-drift-fetch cron job');
  end if;
  if jsonb_array_length(v_nf) > 0 then
    v_flags := v_flags || jsonb_build_object('type', 'not_found', 'files', v_nf,
                                             'note', 'served file missing on main, Pages and the release branch; update the served list');
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
         || case when v_rel_gone then format(' Release branch %s not found.', coalesce(v_rel_ref, '?')) else '' end
         || case when jsonb_array_length(v_nf) > 0 then format(' %s served file(s) found nowhere.', jsonb_array_length(v_nf)) else '' end
  end;
  v_meta := jsonb_build_object('artifact', 'deploy_drift', 'run_id', v_run, 'fetched_at', to_char(v_at at time zone 'UTC', iso),
                               'violations', v_viol, 'flags', v_flags, 'since', v_since,
                               'checked', (select count(*) from public.deploy_drift_requests q where q.run_id = v_run));

  -- One row per UTC day: a second evaluation the same day replaces that day's row.
  select a.id into v_today from public.activity_log a
   where a.meta ->> 'artifact' = 'deploy_drift' and (a.created_at at time zone 'UTC')::date = v_day
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

do $assert$
begin
  if exists (select 1 from unnest(array['public.deploy_drift_fetch(text)', 'public.deploy_drift_evaluate(uuid)',
                                        'public.record_edge_function_deploy(text,integer,text,jsonb,text,timestamptz,text,text)']) f,
                           unnest(array['anon', 'authenticated']) ro
              where has_function_privilege(ro, f, 'execute')) then
    raise exception 'SB-617: a client role can run a deploy-drift function';
  end if;
  if strpos(pg_get_functiondef('public.deploy_drift_evaluate(uuid)'::regprocedure), 'pg_advisory_xact_lock') = 0 then
    raise exception 'SB-617: evaluate is not serialised';
  end if;
end
$assert$;
