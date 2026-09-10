-- SB-439: repair — twelve functions that production has and no migration creates.
--
-- Found by SB-437's branch replay, the first time this history was ever run from
-- scratch. It died at 23 of 240 on 20260419222248_pin_function_search_paths, which
-- ALTERs get_dashboard_activity and get_table_counts — neither of which any
-- migration had created. A further sweep found twelve such functions in total.
--
-- Placed at 20260419222247 so it lands immediately before the migration that first
-- assumes them. `check_function_bodies = off` is what makes one early repair
-- possible: several of these reference tables built much later (project_members
-- arrives 20260604020420, agent_runs at the SB-439 repair below), and without it
-- Postgres would validate the bodies at creation time and reject them. The bodies
-- are validated at first execution instead, by which point the tables exist.
--
-- Definitions are pg_get_functiondef output from production, unmodified. Grants are
-- left at the Postgres default here; the later migrations that REVOKE and re-GRANT
-- these functions (20260508023856, 20260508023951, 20260604010144, 20260802002858)
-- still run and still produce the production ACLs.
--
-- TWO FUNCTIONS ARE DELIBERATELY ABSENT: watch_cip154_dispatch149 and
-- watch_cip165_dispatch166 both embed a literal auth token in a net.http_post
-- header. Committing them would put a live credential in git. Blocked on SB-440,
-- which decides whether to rotate-and-Vault them or drop them. Until then the
-- replay will still complete — nothing references those two — but the routine
-- fingerprint will differ from production by exactly those two rows.

set check_function_bodies = off;

-- ---------------------------------------------------------------- RLS helpers
-- These two are the load-bearing ones. Every RLS policy on this project reduces to
-- them: SB-429 membership, SB-409 OAuth-client scoping and SB-430 role gating all
-- call them from policy predicates. Until this migration their only definition was
-- the live database.

CREATE OR REPLACE FUNCTION public.is_project_member(p_project_id uuid, p_user_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM project_members
    WHERE project_id = p_project_id AND user_id = p_user_id
  );
$function$;

CREATE OR REPLACE FUNCTION public.is_project_owner(p_project_id uuid, p_user_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM project_members
    WHERE project_id = p_project_id AND user_id = p_user_id AND role = 'owner'
  );
$function$;

-- ------------------------------------------------- the two that broke the replay

CREATE OR REPLACE FUNCTION public.get_dashboard_activity(item_limit integer DEFAULT 5)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  result jsonb := '{}'::jsonb;
  mem_data jsonb;
  dec_data jsonb;
  conv_data jsonb;
BEGIN
  -- Recent memories
  SELECT COALESCE(jsonb_agg(row_to_json(m)), '[]'::jsonb)
  INTO mem_data
  FROM (
    SELECT id, type, content, importance, created_at
    FROM public.memories
    WHERE archived = false
    ORDER BY created_at DESC
    LIMIT item_limit
  ) m;

  -- Recent decisions
  SELECT COALESCE(jsonb_agg(row_to_json(d)), '[]'::jsonb)
  INTO dec_data
  FROM (
    SELECT id, title, decision, created_at
    FROM public.decisions
    WHERE archived = false
    ORDER BY created_at DESC
    LIMIT item_limit
  ) d;

  -- Recent conversations
  SELECT COALESCE(jsonb_agg(row_to_json(c)), '[]'::jsonb)
  INTO conv_data
  FROM (
    SELECT id, title, summary, created_at
    FROM public.conversations
    WHERE archived = false
    ORDER BY created_at DESC
    LIMIT item_limit
  ) c;

  result := jsonb_build_object(
    'memories', mem_data,
    'decisions', dec_data,
    'conversations', conv_data
  );

  RETURN result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_table_counts()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  result jsonb := '{}'::jsonb;
  tbl record;
  cnt bigint;
  has_archived boolean;
BEGIN
  FOR tbl IN
    SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
  LOOP
    -- Check if table has an archived column
    SELECT EXISTS(
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = tbl.table_name AND column_name = 'archived'
    ) INTO has_archived;

    IF has_archived THEN
      EXECUTE format('SELECT count(*) FROM public.%I WHERE archived = false', tbl.table_name) INTO cnt;
    ELSE
      EXECUTE format('SELECT count(*) FROM public.%I', tbl.table_name) INTO cnt;
    END IF;

    result := result || jsonb_build_object(tbl.table_name, cnt);
  END LOOP;

  RETURN result;
END;
$function$;

-- ------------------------------------------------------------- agent run RPCs

CREATE OR REPLACE FUNCTION public.start_agent_run(p_agent_id uuid, p_work_item_id uuid DEFAULT NULL::uuid, p_project_id uuid DEFAULT NULL::uuid, p_trigger_type text DEFAULT 'manual'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := (SELECT auth.uid());
  v_run_id uuid;
BEGIN
  -- Verify caller owns this agent
  IF NOT EXISTS (
    SELECT 1 FROM public.agents
    WHERE id = p_agent_id AND user_id = v_user_id
  ) THEN
    RAISE EXCEPTION 'Agent not found or not owned by caller';
  END IF;

  INSERT INTO public.agent_runs (
    user_id, agent_id, work_item_id, project_id,
    started_at, status, trigger_type
  ) VALUES (
    v_user_id, p_agent_id, p_work_item_id, p_project_id,
    now(), 'running', p_trigger_type
  )
  RETURNING id INTO v_run_id;

  -- Increment agent run_count
  UPDATE public.agents
  SET run_count = COALESCE(run_count, 0) + 1,
      last_run_at = now(),
      updated_at = now()
  WHERE id = p_agent_id AND user_id = v_user_id;

  RETURN v_run_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.finish_agent_run(p_run_id uuid, p_status text DEFAULT 'completed'::text, p_tokens_input integer DEFAULT 0, p_tokens_output integer DEFAULT 0, p_tool_calls integer DEFAULT 0, p_api_calls integer DEFAULT 0, p_items_created integer DEFAULT 0, p_items_updated integer DEFAULT 0, p_result_summary text DEFAULT NULL::text, p_error_message text DEFAULT NULL::text, p_error_code text DEFAULT NULL::text, p_run_metadata jsonb DEFAULT NULL::jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := (SELECT auth.uid());
  v_agent_id uuid;
  v_duration_ms bigint;
BEGIN
  -- Verify caller owns this run
  SELECT agent_id INTO v_agent_id
  FROM public.agent_runs
  WHERE id = p_run_id AND user_id = v_user_id AND status = 'running';

  IF v_agent_id IS NULL THEN
    RAISE EXCEPTION 'Run not found, not owned by caller, or not in running status';
  END IF;

  -- Update the run with final metrics
  UPDATE public.agent_runs
  SET 
    finished_at = now(),
    status = p_status,
    tokens_input = p_tokens_input,
    tokens_output = p_tokens_output,
    tool_calls = p_tool_calls,
    api_calls = p_api_calls,
    items_created = p_items_created,
    items_updated = p_items_updated,
    result_summary = p_result_summary,
    error_message = p_error_message,
    error_code = p_error_code,
    run_metadata = p_run_metadata
  WHERE id = p_run_id AND user_id = v_user_id;

  -- Get computed duration for agent stats update
  SELECT duration_ms INTO v_duration_ms
  FROM public.agent_runs WHERE id = p_run_id;

  -- Update agent-level stats
  IF p_status = 'failed' THEN
    UPDATE public.agents
    SET error_count = COALESCE(error_count, 0) + 1,
        last_error = p_error_message,
        avg_duration_ms = CASE 
          WHEN avg_duration_ms IS NULL THEN v_duration_ms
          ELSE (COALESCE(avg_duration_ms, 0) + v_duration_ms) / 2
        END,
        updated_at = now()
    WHERE id = v_agent_id AND user_id = v_user_id;
  ELSE
    UPDATE public.agents
    SET avg_duration_ms = CASE 
          WHEN avg_duration_ms IS NULL THEN v_duration_ms
          ELSE (COALESCE(avg_duration_ms, 0) + v_duration_ms) / 2
        END,
        updated_at = now()
    WHERE id = v_agent_id AND user_id = v_user_id;
  END IF;
END;
$function$;

-- ------------------------------------------------------------ trigger functions

CREATE OR REPLACE FUNCTION public.enforce_epic_linkage()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_epic uuid;
BEGIN
  -- Only act on orphan tasks/chores with a project
  IF NEW.type IN ('task','chore') AND NEW.parent_id IS NULL AND NEW.project_id IS NOT NULL THEN
    SELECT id INTO v_epic FROM work_items
      WHERE project_id = NEW.project_id AND type='epic' AND (meta->>'catch_all')='true'
      LIMIT 1;
    IF v_epic IS NULL THEN
      -- self-heal: create the project's catch-all epic (epic type won't re-trigger this branch)
      INSERT INTO work_items (project_id, user_id, title, type, status, priority, approval_status, sort_order, meta)
      VALUES (NEW.project_id, NEW.user_id, 'Catch-All — Unsorted', 'epic', 'backlog', 'low', 'not_required', 9999,
              jsonb_build_object('catch_all', true, 'created_by','SB-231-trigger'))
      RETURNING id INTO v_epic;
    END IF;
    NEW.parent_id := v_epic;
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.protect_sentinel_columns()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  -- If sentinel_cleared is being changed
  IF OLD.sentinel_cleared IS DISTINCT FROM NEW.sentinel_cleared THEN
    -- Only allow if status is 'proposed' (Sentinel reviewing a new signal)
    IF OLD.status NOT IN ('proposed') THEN
      RAISE EXCEPTION 'sentinel_cleared can only be modified on proposed signals (current status: %)', OLD.status;
    END IF;
  END IF;
  
  -- If sentinel_verdict is being changed  
  IF OLD.sentinel_verdict IS DISTINCT FROM NEW.sentinel_verdict THEN
    IF OLD.status NOT IN ('proposed') THEN
      RAISE EXCEPTION 'sentinel_verdict can only be modified on proposed signals (current status: %)', OLD.status;
    END IF;
  END IF;
  
  -- Prevent revoking clearance once granted
  IF OLD.sentinel_cleared = true AND NEW.sentinel_cleared = false THEN
    RAISE EXCEPTION 'Cannot revoke sentinel clearance once granted';
  END IF;
  
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.fn_normalize_skill_file_path()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
  cm_prefix TEXT := '/Users/Jason/Library/CloudStorage/CloudMounter-JasonPaulsen/AI/Skills/';
  ai_prefix TEXT := '/AI/Skills/';
BEGIN
  -- Normalize file_path
  IF NEW.file_path IS NOT NULL AND NEW.file_path LIKE '/%' THEN
    -- First try the full CloudMounter prefix
    IF starts_with(NEW.file_path, cm_prefix) THEN
      NEW.file_path := substring(NEW.file_path FROM length(cm_prefix) + 1);
    -- Then try the /AI/Skills/ prefix
    ELSIF starts_with(NEW.file_path, ai_prefix) THEN
      NEW.file_path := substring(NEW.file_path FROM length(ai_prefix) + 1);
    -- For any other absolute path containing /AI/Skills/, extract from there
    ELSIF position('/AI/Skills/' IN NEW.file_path) > 0 THEN
      NEW.file_path := substring(NEW.file_path FROM position('/AI/Skills/' IN NEW.file_path) + length('/AI/Skills/'));
    END IF;
    -- If still absolute after all normalization attempts, the CHECK constraint
    -- will reject it — which is the correct behavior for unknown paths.
  END IF;

  -- Also normalize source_path if it has a full CloudMounter prefix
  IF NEW.source_path IS NOT NULL AND starts_with(NEW.source_path, cm_prefix) THEN
    NEW.source_path := substring(NEW.source_path FROM length(cm_prefix) + 1);
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.fn_trigger_skill_embedding()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
  project_url text := 'https://hzqqvbvhnzmgqivfigej.supabase.co';
  request_id bigint;
BEGIN
  SELECT net.http_post(
    url := project_url || '/functions/v1/generate-skill-embeddings',
    body := jsonb_build_object('skill_id', NEW.skill_id),
    headers := '{"Content-Type": "application/json"}'::jsonb
  ) INTO request_id;
  RETURN NEW;
END;
$function$;

-- ------------------------------------------------------------------ operations

CREATE OR REPLACE FUNCTION public.classroom_get_secret(secret_name text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'vault', 'pg_temp'
AS $function$
  SELECT decrypted_secret
  FROM vault.decrypted_secrets
  WHERE name = secret_name
    AND name LIKE 'google\_classroom\_%'
$function$;

CREATE OR REPLACE FUNCTION public.cron_health_check()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_failures jsonb;
  v_stale jsonb;
  v_summary text;
begin
  -- Failed runs in the last 24h
  select coalesce(jsonb_agg(jsonb_build_object('job', j.jobname, 'at', d.end_time, 'error', left(d.return_message, 200)) order by d.end_time desc), '[]'::jsonb)
    into v_failures
  from cron.job_run_details d join cron.job j on j.jobid=d.jobid
  where d.end_time > now() - interval '24 hours' and d.status = 'failed';

  -- Active jobs that have not run at all in the last 25h (scheduler-dead detection).
  -- Catches the failure mode a failure-log check misses: a job that silently stopped firing.
  select coalesce(jsonb_agg(jsonb_build_object('job', j.jobname, 'schedule', j.schedule)), '[]'::jsonb)
    into v_stale
  from cron.job j
  where j.active
    and not exists (select 1 from cron.job_run_details d
                    where d.jobid=j.jobid and d.start_time > now() - interval '25 hours');

  v_summary := case
    when jsonb_array_length(v_failures)=0 and jsonb_array_length(v_stale)=0
      then 'Cron health: all clear — every active job ran, zero failures in 24h.'
    else format('Cron health: %s failed run(s), %s silent job(s) in 24h.',
                jsonb_array_length(v_failures), jsonb_array_length(v_stale))
  end;

  -- One row per day, clean or not: silence must be distinguishable from a dead monitor.
  insert into activity_log (project_id, user_id, agent_name, action, target_table, summary, meta)
  values ('a07a7f3d-722f-468f-81fa-84e2c5fba704','5ecbd44a-a3e2-4363-9133-dff3851ba0f5',
          'System','commented','cron_health', v_summary,
          jsonb_build_object('artifact','cron_health','failures',v_failures,'silent_jobs',v_stale));

  return jsonb_build_object('summary', v_summary, 'failures', v_failures, 'silent_jobs', v_stale);
end $function$;

reset check_function_bodies;
