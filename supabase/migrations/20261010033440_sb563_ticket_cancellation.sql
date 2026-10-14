-- SB-563: ticket cancellation as a terminal state (ADR-FLOW-004; decisions D1-D4 by Jason, 2026-10-10).
--
-- 1. status 'cancelled' + five cancel_* columns, with an all-or-nothing CHECK
-- 2. enforce_cancellation(): reason/note/replacement rules, authority by level,
--    parent guard, field lock, reopen rules and history
-- 3. governance_audit: decisions 'cancelled' / 'reopened' for every transition
-- 4. reads that treated "not done" as open now treat cancelled as closed
-- 5. RPCs cancel_work_item / reopen_work_item and the v_recent_cancellations feed
-- 6. authority_action_map entry ticket_cancellation
-- 7. backfill of the clear meta.closure_reason rows (D4)

-- 1 ---------------------------------------------------------------------------
alter table public.work_items drop constraint work_items_status_check;
alter table public.work_items add constraint work_items_status_check
  check (status = any (array['backlog','todo','in_progress','review','done','escalated',
                             'blocked','on_hold','awaiting_jason','cancelled']));

alter table public.work_items
  add column cancel_reason text
    constraint work_items_cancel_reason_check
    check (cancel_reason in ('duplicate','superseded','no_longer_relevant','wont_do','rejected_by_jason')),
  add column cancel_note text,
  add column cancel_replaced_by uuid references public.work_items(id) on delete set null,
  add column cancelled_at timestamptz,
  add column cancelled_by text;

alter table public.work_items add constraint work_items_cancel_fields_check check (
  (status = 'cancelled' and cancel_reason is not null and cancelled_at is not null and cancelled_by is not null)
  or (status <> 'cancelled' and cancel_reason is null and cancel_note is null
      and cancel_replaced_by is null and cancelled_at is null and cancelled_by is null));

create index work_items_cancel_replaced_by_idx on public.work_items (cancel_replaced_by)
  where cancel_replaced_by is not null;

comment on column public.work_items.cancel_reason is
  'SB-563 / ADR-FLOW-004: why a cancelled ticket was retired. Set only while status = cancelled.';
comment on column public.work_items.cancelled_by is
  'SB-563: the actor who cancelled (caller-written, same trust model as approved_by).';

-- 2 ---------------------------------------------------------------------------
create or replace function public.enforce_cancellation()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_actor  text;
  v_lvl    int := coalesce(new.authority_level, 1);
  v_jason  boolean;
  v_fields_set boolean := (new.cancel_reason is not null or new.cancel_note is not null
                           or new.cancel_replaced_by is not null or new.cancelled_at is not null
                           or new.cancelled_by is not null);
  v_hist   jsonb;
begin
  if tg_op = 'INSERT' then
    if new.status = 'cancelled' then
      raise exception 'CANCEL-007: % cannot be created as cancelled; create it, then cancel it', coalesce(new.ticket_code, 'a new ticket');
    end if;
    if v_fields_set then
      raise exception 'CANCEL-001: cancel_* fields are set only by cancelling a ticket';
    end if;
    return new;
  end if;

  -- staying cancelled: the decision is locked
  if old.status = 'cancelled' and new.status = 'cancelled' then
    if (new.cancel_reason, new.cancel_note, new.cancel_replaced_by, new.cancelled_at, new.cancelled_by)
       is distinct from
       (old.cancel_reason, old.cancel_note, old.cancel_replaced_by, old.cancelled_at, old.cancelled_by) then
      raise exception 'CANCEL-006: % is cancelled; its cancellation cannot be edited. Reopen it, then cancel it again', old.ticket_code;
    end if;
    return new;
  end if;

  -- leaving cancelled: reopen
  if old.status = 'cancelled' then
    if new.status not in ('backlog','todo','awaiting_jason') then
      raise exception 'CANCEL-005: % can only be reopened to backlog, todo or awaiting_jason (not %)', old.ticket_code, new.status;
    end if;
    if (v_lvl >= 3 or old.cancel_reason = 'rejected_by_jason') and new.status <> 'awaiting_jason' then
      raise exception 'CANCEL-005: % (L%, %) can only be reopened to awaiting_jason, so Jason decides again',
        old.ticket_code, v_lvl, old.cancel_reason;
    end if;
    v_hist := jsonb_build_object(
      'reason', old.cancel_reason, 'note', old.cancel_note,
      'replaced_by', old.cancel_replaced_by, 'cancelled_at', old.cancelled_at,
      'cancelled_by', old.cancelled_by, 'reopened_at', now(),
      'reopened_by', coalesce(new.meta->>'reopened_by', new.assignee, 'system'),
      'reopened_to', new.status);
    new.meta := (coalesce(new.meta, '{}'::jsonb) - 'reopened_by')
                || jsonb_build_object('cancel_history',
                     coalesce(new.meta->'cancel_history', '[]'::jsonb) || jsonb_build_array(v_hist));
    new.cancel_reason := null; new.cancel_note := null; new.cancel_replaced_by := null;
    new.cancelled_at := null;  new.cancelled_by := null;
    return new;
  end if;

  -- not involved in a cancellation
  if new.status <> 'cancelled' then
    if v_fields_set then
      raise exception 'CANCEL-001: % is %, not cancelled; cancel_* fields are set only by cancelling it', new.ticket_code, new.status;
    end if;
    return new;
  end if;

  -- entering cancelled
  v_actor := btrim(coalesce(new.cancelled_by, ''));
  if new.cancel_reason is null then
    raise exception 'CANCEL-001: cancelling % needs cancel_reason (duplicate, superseded, no_longer_relevant, wont_do, rejected_by_jason)', new.ticket_code;
  end if;
  if v_actor = '' then
    raise exception 'CANCEL-001: cancelling % needs cancelled_by (who is cancelling it)', new.ticket_code;
  end if;
  if new.cancel_reason in ('duplicate','superseded') then
    if new.cancel_replaced_by is null or new.cancel_replaced_by = new.id then
      raise exception 'CANCEL-002: % cancelled as % must name the other ticket in cancel_replaced_by (not itself)',
        new.ticket_code, new.cancel_reason;
    end if;
  elsif length(btrim(coalesce(new.cancel_note, ''))) < 3 then
    raise exception 'CANCEL-002: % cancelled as % needs a one-line cancel_note', new.ticket_code, new.cancel_reason;
  end if;

  v_jason := v_actor ~* '^jason';
  if new.cancel_reason = 'rejected_by_jason' and not v_jason then
    raise exception 'CANCEL-003: only Jason can cancel % as rejected_by_jason (actor: %)', new.ticket_code, v_actor;
  end if;
  if (v_lvl >= 3 or old.status = 'awaiting_jason') and not v_jason then
    raise exception 'CANCEL-003: only Jason can cancel % (L%, status %; actor: %)',
      new.ticket_code, v_lvl, old.status, v_actor;
  end if;
  if v_lvl = 2 and not (v_jason or v_actor ~* '^jarvis' or v_actor ~ '(^|\s)PM($|\s)' or v_actor ~* 'project manager') then
    raise exception 'CANCEL-003: % is L2 — a PM, JARVIS or Jason must cancel it (actor: %)', new.ticket_code, v_actor;
  end if;

  if exists (select 1 from public.work_items c
              where c.parent_id = new.id and c.status not in ('done','cancelled') and not c.archived) then
    raise exception 'CANCEL-004: % still has open children; close or cancel them first', new.ticket_code;
  end if;

  new.cancelled_by := v_actor;
  -- The SB-563 backfill keeps each row's historical close time; everything else is stamped now.
  new.cancelled_at := case when current_setting('supabrain.cancel_backfill', true) = 'on' and new.cancelled_at is not null
                           then new.cancelled_at else now() end;
  -- GOV-001 lets a ticket leave awaiting_jason only on Jason's decision; a cancellation by
  -- Jason is that decision (trg_enforce_authority_governance runs after this trigger).
  if old.status = 'awaiting_jason' and v_jason then
    new.approval_status := 'rejected';
    new.approved_by := 'Jason';
    new.approved_at := now();
  end if;
  return new;
end;
$$;

create trigger trg_cancellation
  before insert or update on public.work_items
  for each row execute function public.enforce_cancellation();

create or replace function public.enforce_archived_implies_done()
returns trigger
language plpgsql
as $$
begin
  -- SB-563: a cancelled ticket is terminal too, so it may be archived like a done one.
  if new.status not in ('done','cancelled') and new.archived then
    new.archived := false;
    new.archived_at := null;
  end if;
  return new;
end;
$$;

-- 3 ---------------------------------------------------------------------------
alter table public.governance_audit drop constraint governance_audit_decision_check;
alter table public.governance_audit add constraint governance_audit_decision_check
  check (decision = any (array['approved','rejected','auto','deferred','escalated','notified',
                               'un_approve','un_reject','cancelled','reopened']));

create or replace function public.audit_authority_governance()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
DECLARE
  old_status text;
  jason_decided boolean;
  audit_decision text;
BEGIN
  -- SB-563: every cancellation and reopen is audited, whatever the authority level.
  IF TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status
     AND (NEW.status = 'cancelled' OR OLD.status = 'cancelled') THEN
    INSERT INTO governance_audit (user_id, work_item_id, from_status, to_status, authority_level, action_category, decided_by, decision, confidence, notes)
    VALUES (NEW.user_id, NEW.id, OLD.status, NEW.status, NEW.authority_level, NEW.action_category,
            CASE WHEN NEW.status = 'cancelled' THEN NEW.cancelled_by
                 ELSE COALESCE(NEW.meta->'cancel_history'->-1->>'reopened_by', NEW.assignee, 'system') END,
            CASE WHEN NEW.status = 'cancelled' THEN 'cancelled' ELSE 'reopened' END,
            NULL,
            CASE WHEN NEW.status = 'cancelled'
                 THEN format('trigger: audit_authority_governance; reason=%s; replaced_by=%s; note=%s',
                             NEW.cancel_reason, NEW.cancel_replaced_by, left(NEW.cancel_note, 300))
                 ELSE format('trigger: audit_authority_governance; reopened (was %s)', OLD.cancel_reason) END);
    RETURN NEW;
  END IF;

  IF NEW.authority_level IS NULL THEN RETURN NEW; END IF;
  old_status := CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE OLD.status END;
  IF NEW.status IS NOT DISTINCT FROM old_status THEN RETURN NEW; END IF;
  jason_decided := COALESCE(NEW.approved_by, '') ILIKE 'jason%';
  audit_decision := CASE
    WHEN NEW.status = 'awaiting_jason' THEN 'escalated'
    WHEN old_status = 'awaiting_jason' AND NEW.approval_status = 'approved' THEN 'approved'
    WHEN old_status = 'awaiting_jason' AND NEW.approval_status = 'rejected' THEN 'rejected'
    WHEN NEW.authority_level = 1 AND NEW.status = 'done' THEN 'notified'
    ELSE 'auto' END;
  INSERT INTO governance_audit (user_id, work_item_id, from_status, to_status, authority_level, action_category, decided_by, decision, confidence, notes)
  VALUES (NEW.user_id, NEW.id, old_status, NEW.status, NEW.authority_level, NEW.action_category,
          CASE WHEN jason_decided THEN 'jason' ELSE COALESCE(NEW.assignee,'system') END,
          audit_decision,
          NULLIF(NEW.meta->'governance'->>'confidence','')::numeric,
          'trigger: audit_authority_governance');
  RETURN NEW;
END $$;

-- 4 ---------------------------------------------------------------------------
create or replace view public.jarvis_ops_metrics with (security_invoker = true) as
 WITH agent_perf AS (
         SELECT agent_runs.agent_id,
            count(*) AS total_runs,
            count(*) FILTER (WHERE (agent_runs.status = 'failed'::text)) AS failed_runs,
            round(avg(agent_runs.duration_ms) FILTER (WHERE (agent_runs.status = 'completed'::text)), 0) AS avg_duration_ms,
            percentile_cont((0.95)::double precision) WITHIN GROUP (ORDER BY ((agent_runs.duration_ms)::double precision)) FILTER (WHERE (agent_runs.status = 'completed'::text)) AS p95_duration_ms,
            round(avg(agent_runs.tokens_total) FILTER (WHERE (agent_runs.status = 'completed'::text)), 0) AS avg_tokens,
            max(agent_runs.started_at) AS last_run
           FROM agent_runs
          GROUP BY agent_runs.agent_id
        ), work_health AS (
         SELECT work_items.user_id,
            count(*) FILTER (WHERE (work_items.status <> 'cancelled'::text)) AS total_items,
            count(*) FILTER (WHERE (work_items.status = 'done'::text)) AS done_items,
            count(*) FILTER (WHERE ((work_items.status <> ALL (ARRAY['done'::text, 'cancelled'::text, 'backlog'::text])) AND (work_items.updated_at < (now() - '14 days'::interval)))) AS stale_items,
            count(*) FILTER (WHERE ((work_items.due_date < CURRENT_DATE) AND (work_items.status <> ALL (ARRAY['done'::text, 'cancelled'::text])))) AS overdue_items,
            count(*) FILTER (WHERE ((work_items.status = ANY (ARRAY['in_progress'::text, 'review'::text])) AND (work_items.updated_at < (now() - '7 days'::interval)))) AS blocked_items,
            count(*) FILTER (WHERE ((work_items.assigned_agent_id IS NULL) AND (work_items.status <> ALL (ARRAY['done'::text, 'cancelled'::text, 'backlog'::text])))) AS unassigned_items,
            count(*) FILTER (WHERE (work_items.status = 'cancelled'::text)) AS cancelled_items
           FROM work_items
          GROUP BY work_items.user_id
        ), test_health AS (
         SELECT test_cases.user_id,
            count(*) AS total_cases,
            count(*) FILTER (WHERE (test_cases.status = 'passed'::text)) AS passed,
            count(*) FILTER (WHERE (test_cases.status = 'failed'::text)) AS failed,
                CASE
                    WHEN (count(*) FILTER (WHERE (test_cases.status = ANY (ARRAY['passed'::text, 'failed'::text]))) > 0) THEN round((((count(*) FILTER (WHERE (test_cases.status = 'passed'::text)))::numeric / (count(*) FILTER (WHERE (test_cases.status = ANY (ARRAY['passed'::text, 'failed'::text]))))::numeric) * (100)::numeric), 1)
                    ELSE (0)::numeric
                END AS pass_rate
           FROM test_cases
          GROUP BY test_cases.user_id
        ), briefing_health AS (
         SELECT DISTINCT ON (jarvis_briefings.user_id) jarvis_briefings.user_id,
            COALESCE(jsonb_array_length(jarvis_briefings.recommendations), 0) AS open_recommendations,
            COALESCE(jsonb_array_length(jarvis_briefings.flags), 0) AS open_flags,
            jarvis_briefings.briefing_date AS last_briefing_date
           FROM jarvis_briefings
          ORDER BY jarvis_briefings.user_id, jarvis_briefings.briefing_date DESC
        )
 SELECT wh.user_id,
    wh.total_items,
    wh.done_items,
        CASE
            WHEN (wh.total_items > 0) THEN round((((wh.done_items)::numeric / (wh.total_items)::numeric) * (100)::numeric), 1)
            ELSE (0)::numeric
        END AS completion_pct,
    wh.stale_items,
    wh.overdue_items,
    wh.blocked_items,
    wh.unassigned_items,
    COALESCE(th.pass_rate, (0)::numeric) AS test_pass_rate,
    COALESCE(th.total_cases, (0)::bigint) AS total_test_cases,
    COALESCE(th.failed, (0)::bigint) AS failed_tests,
    COALESCE(bh.open_recommendations, 0) AS open_recommendations,
    COALESCE(bh.open_flags, 0) AS open_flags,
    bh.last_briefing_date,
    ( SELECT count(*) AS count
           FROM agent_runs
          WHERE (agent_runs.status = 'failed'::text)) AS total_agent_failures,
    ( SELECT round(avg(agent_runs.duration_ms), 0) AS round
           FROM agent_runs
          WHERE (agent_runs.status = 'completed'::text)) AS avg_agent_duration_ms,
    ( SELECT percentile_cont((0.95)::double precision) WITHIN GROUP (ORDER BY ((agent_runs.duration_ms)::double precision)) AS percentile_cont
           FROM agent_runs
          WHERE (agent_runs.status = 'completed'::text)) AS p95_agent_duration_ms,
    wh.cancelled_items
   FROM ((work_health wh
     LEFT JOIN test_health th ON ((th.user_id = wh.user_id)))
     LEFT JOIN briefing_health bh ON ((bh.user_id = wh.user_id)));

create or replace view public.kanban_board_view with (security_invoker = true) as
 SELECT w.id,
    w.project_id,
    w.user_id,
    w.ticket_code,
    w.title,
    w.description,
    w.type,
    w.status,
    w.priority,
    w.sort_order,
    w.assignee,
    w.due_date,
    w.source_table,
    w.source_id,
    w.created_at,
    w.updated_at,
    w.completed_at,
    w.assigned_agent_id,
    w.approved_by,
    w.approved_at,
    w.approval_status,
    w.parent_id,
    w.acknowledged,
    w.acknowledged_at,
    w.snoozed_until,
    parent.title AS parent_title,
    p.name AS project_name,
    p.icon AS project_icon,
    p.project_key,
    p.domain AS project_domain,
    a.name AS agent_name,
    a.icon AS agent_icon,
    a.status AS agent_status,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name, 'color', l.color)) AS jsonb_agg
           FROM (work_item_labels wl
             JOIN labels l ON ((l.id = wl.label_id)))
          WHERE (wl.work_item_id = w.id)), '[]'::jsonb) AS labels,
    ( SELECT count(*) AS count
           FROM work_item_comments c
          WHERE (c.work_item_id = w.id)) AS comment_count,
    ( SELECT count(*) AS count
           FROM work_items child
          WHERE ((child.parent_id = w.id) AND (child.status <> 'cancelled'::text))) AS child_count,
    ( SELECT count(*) AS count
           FROM work_items child
          WHERE ((child.parent_id = w.id) AND (child.status = 'done'::text))) AS completed_child_count,
    ( SELECT count(*) AS count
           FROM (work_item_links wil
             JOIN work_items blocker ON ((blocker.id = wil.from_item_id)))
          WHERE ((wil.to_item_id = w.id) AND (wil.link_type = 'blocks'::text) AND (blocker.status <> ALL (ARRAY['done'::text, 'cancelled'::text])))) AS blocked_by_count,
    w.archived,
    w.archived_at,
    w.hold_reason,
    w.held_by_gate,
    w.cancel_reason,
    w.cancel_note,
    w.cancel_replaced_by,
    w.cancelled_at,
    w.cancelled_by
   FROM (((work_items w
     JOIN projects p ON ((p.id = w.project_id)))
     LEFT JOIN agents a ON ((a.id = w.assigned_agent_id)))
     LEFT JOIN work_items parent ON ((parent.id = w.parent_id)));

create or replace function public.archive_work_items(p_dry_run boolean default true, p_days integer default 14, p_force boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_run_id uuid := gen_random_uuid();
  v_ids uuid[];
  v_count integer;
  v_median numeric;
  v_guard integer;
  v_project_id uuid;
  v_user_id uuid;
begin
  -- §4.2 age from completed_at, never updated_at (updated_at is rewritten by
  -- trigger_update_updated_at on every write, which makes it non-idempotent).
  -- §5 exclusions: null completed_at, and any row with a non-done child.
  -- Retention is per project (projects.meta.archive_after_days) with p_days as
  -- the global default.
  -- SB-563: a cancelled row ages from cancelled_at under the same retention, and a
  -- cancelled child no longer holds its parent back.
  select array_agg(w.id) into v_ids
  from work_items w
  join projects pr on pr.id = w.project_id
  where w.archived = false
    and coalesce(case w.status when 'done' then w.completed_at
                               when 'cancelled' then w.cancelled_at end, 'infinity'::timestamptz)
        < now() - make_interval(
          days => coalesce((pr.meta->>'archive_after_days')::int, p_days))
    and not exists (
      select 1 from work_items c
      where c.parent_id = w.id and c.status not in ('done', 'cancelled')
    );

  v_count := coalesce(array_length(v_ids, 1), 0);

  -- §5 anomaly guard. cron.job_run_details shows 23% of runs on this project fail;
  -- a sweep that fails silently is the default outcome here, not the exception.
  -- Forced runs are excluded from the baseline: they are human-approved one-offs
  -- (the 655-row catch-up was one) and letting them set the median would raise the
  -- guard to 1310 and defeat the check for ordinary unattended nights.
  select percentile_cont(0.5) within group (order by (meta->>'count')::numeric)
    into v_median
  from activity_log
  where target_table = 'work_items'
    and meta->>'archive_run_id' is not null
    and meta->>'mode' = 'live'
    and (meta->>'forced')::boolean is not true;

  v_guard := greatest(50, coalesce((v_median * 2)::int, 0));

  if not p_dry_run and not p_force and v_count > v_guard then
    return jsonb_build_object(
      'run_id', v_run_id, 'mode', 'aborted', 'count', v_count,
      'guard', v_guard, 'trailing_median', v_median,
      'reason', 'candidate count exceeds anomaly guard; re-run with p_force => true to approve explicitly'
    );
  end if;

  if p_dry_run then
    return jsonb_build_object(
      'run_id', v_run_id, 'mode', 'dry_run', 'count', v_count,
      'guard', v_guard, 'days', p_days,
      'would_archive', to_jsonb(coalesce(v_ids, '{}'::uuid[]))
    );
  end if;

  if v_count = 0 then
    return jsonb_build_object('run_id', v_run_id, 'mode', 'live', 'count', 0);
  end if;

  -- §4.5 run identity: without it there is no rollback.
  update work_items
  set archived = true,
      archived_at = now(),
      meta = coalesce(meta, '{}'::jsonb) || jsonb_build_object('archive_run_id', v_run_id::text)
  where id = any(v_ids);

  -- §4.5 ONE summary row per run, not one per item.
  select project_id, user_id into v_project_id, v_user_id
  from work_items where id = v_ids[1];

  insert into activity_log (project_id, user_id, agent_name, action, target_table, target_id, summary, meta)
  values (
    v_project_id, v_user_id, 'archive_work_items', 'archived', 'work_items', null,
    format('Archived %s done or cancelled work items older than %s days (run %s).', v_count, p_days, v_run_id),
    jsonb_build_object(
      'archive_run_id', v_run_id::text, 'mode', 'live', 'count', v_count,
      'days', p_days, 'forced', p_force, 'ids', to_jsonb(v_ids)
    )
  );

  return jsonb_build_object('run_id', v_run_id, 'mode', 'live', 'count', v_count, 'forced', p_force);
end;
$$;

-- In-place patches: each refuses unless its source still has exactly the text it replaces.
do $patch$
declare
  v_def text;
  v_n int;
begin
  -- generate_daily_audit: every "open" filter excludes cancelled; flow_metrics counts it
  v_def := pg_get_functiondef('public.generate_daily_audit(uuid,uuid,date,uuid)'::regprocedure);
  v_n := (length(v_def) - length(replace(v_def, 'NOT IN (''done'',''backlog'')', ''))) / length('NOT IN (''done'',''backlog'')');
  if v_n < 6 or strpos(v_def, 'status != ''done''') = 0
     or strpos(v_def, '''done'', COUNT(*) FILTER (WHERE status = ''done''),') = 0 then
    raise exception 'SB-563 patch: generate_daily_audit is not the expected body (open filters: %)', v_n;
  end if;
  v_def := replace(v_def, 'NOT IN (''done'',''backlog'')', 'NOT IN (''done'',''cancelled'',''backlog'')');
  v_def := replace(v_def, 'status != ''done''', 'status NOT IN (''done'',''cancelled'')');
  v_def := replace(v_def, '''done'', COUNT(*) FILTER (WHERE status = ''done''),',
                          '''done'', COUNT(*) FILTER (WHERE status = ''done''),' || E'\n    '
                          || '''cancelled'', COUNT(*) FILTER (WHERE status = ''cancelled''),');
  execute v_def;

  -- crm_steward_scheduled: a cancelled failure ticket must not suppress the next one
  v_def := pg_get_functiondef('public.crm_steward_scheduled(text)'::regprocedure);
  if (length(v_def) - length(replace(v_def, 'w.status <> ''done''', ''))) / length('w.status <> ''done''') <> 1 then
    raise exception 'SB-563 patch: crm_steward_scheduled is not the expected body';
  end if;
  execute replace(v_def, 'w.status <> ''done''', 'w.status not in (''done'', ''cancelled'')');

  -- sync_school_assignment_to_fam: never move a cancelled FAM reminder to done
  v_def := pg_get_functiondef('public.sync_school_assignment_to_fam(uuid)'::regprocedure);
  if (length(v_def) - length(replace(v_def, 'v_wi_status <> ''done''', ''))) / length('v_wi_status <> ''done''') <> 1 then
    raise exception 'SB-563 patch: sync_school_assignment_to_fam is not the expected body';
  end if;
  execute replace(v_def, 'v_wi_status <> ''done''', 'v_wi_status NOT IN (''done'',''cancelled'')');
end
$patch$;

-- 5 ---------------------------------------------------------------------------
create or replace function public.cancel_work_item(
  p_item_id uuid, p_reason text, p_note text default null,
  p_replaced_by text default null, p_actor text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_item public.work_items%rowtype;
  v_repl uuid;
begin
  select * into v_item from public.work_items where id = p_item_id and user_id = auth.uid();
  if not found then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if p_replaced_by is not null then
    select id into v_repl from public.work_items
     where user_id = v_item.user_id and ticket_code = upper(btrim(p_replaced_by));
    if v_repl is null then
      raise exception 'CANCEL-002: replacing ticket % not found', p_replaced_by;
    end if;
  end if;
  update public.work_items
     set status = 'cancelled', cancel_reason = p_reason, cancel_note = nullif(btrim(p_note), ''),
         cancel_replaced_by = v_repl, cancelled_by = p_actor
   where id = p_item_id
  returning * into v_item;
  return jsonb_build_object('ticket_code', v_item.ticket_code, 'status', v_item.status,
                            'cancel_reason', v_item.cancel_reason, 'cancelled_at', v_item.cancelled_at,
                            'cancelled_by', v_item.cancelled_by);
end;
$$;

create or replace function public.reopen_work_item(p_item_id uuid, p_status text default 'backlog', p_actor text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_item public.work_items%rowtype;
begin
  select * into v_item from public.work_items where id = p_item_id and user_id = auth.uid();
  if not found then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if v_item.status <> 'cancelled' then
    raise exception 'CANCEL-005: % is %, not cancelled', v_item.ticket_code, v_item.status;
  end if;
  update public.work_items
     set status = p_status,
         meta = coalesce(meta, '{}'::jsonb)
                || case when p_actor is null then '{}'::jsonb else jsonb_build_object('reopened_by', p_actor) end
   where id = p_item_id
  returning * into v_item;
  return jsonb_build_object('ticket_code', v_item.ticket_code, 'status', v_item.status);
end;
$$;

revoke all on function public.cancel_work_item(uuid, text, text, text, text) from public, anon;
revoke all on function public.reopen_work_item(uuid, text, text) from public, anon;
grant execute on function public.cancel_work_item(uuid, text, text, text, text) to authenticated, service_role;
grant execute on function public.reopen_work_item(uuid, text, text) to authenticated, service_role;
revoke all on function public.enforce_cancellation() from public, anon, authenticated;

create or replace view public.v_recent_cancellations with (security_invoker = true) as
select w.user_id, w.ticket_code, w.title, w.authority_level, w.cancel_reason, w.cancel_note,
       r.ticket_code as replaced_by, w.cancelled_by, w.cancelled_at,
       (coalesce(w.authority_level, 1) = 2 and w.cancelled_by !~* '^jason') as tell_jason
  from public.work_items w
  left join public.work_items r on r.id = w.cancel_replaced_by
 where w.status = 'cancelled' and w.cancelled_at > now() - interval '7 days';
comment on view public.v_recent_cancellations is
  'SB-563: the "Retired" line for JARVIS briefings. Cancelled items never count as accomplishments; tell_jason marks L2 cancellations made by someone other than Jason.';
revoke all on public.v_recent_cancellations from anon;
grant select on public.v_recent_cancellations to authenticated, service_role;

-- 6 ---------------------------------------------------------------------------
insert into public.authority_action_map (action_category, default_level, escalation_triggers, notes)
values ('ticket_cancellation', 1, array['authority_level >= 3', 'status = awaiting_jason', 'reason = rejected_by_jason'],
        'SB-562 / ADR-FLOW-004 §4: the effective level is the cancelled ticket''s own (NULL counts as L1). L0-L1 any agent; L2 a PM, JARVIS or Jason (Jason told via v_recent_cancellations); L3-L4, awaiting_jason or rejected_by_jason only Jason. Do not use meta.approval_gate_exempt to retire a ticket.');

-- 7 ---------------------------------------------------------------------------
do $backfill$
declare
  v_expected int;
  v_done int;
  v_left int;
begin
  perform set_config('supabrain.cancel_backfill', 'on', true);
  create temporary table sb563_backfill on commit drop as
  select w.id, w.ticket_code, w.meta->>'closure_reason' as cr, w.completed_at,
         case
           when w.meta->>'closure_reason' = 'duplicate' and w.meta ? 'duplicate_of' then 'duplicate'
           when (w.meta->>'closure_reason' = 'superseded' and w.meta ? 'superseded_by')
                or w.meta->>'closure_reason' like 'consolidated_into_%' then 'superseded'
           else 'no_longer_relevant'
         end as reason,
         (select r.id from public.work_items r
           where r.user_id = w.user_id
             and r.ticket_code = (regexp_match(coalesce(w.meta->>'duplicate_of', w.meta->>'superseded_by',
                                                        replace(w.meta->>'closure_reason', '_', ' ')),
                                               '([0-9A-Z]+-[0-9]+)'))[1]) as repl
    from public.work_items w
   where w.status = 'done' and w.meta ? 'closure_reason'
     and w.meta->>'closure_reason' !~* '^fixed:';
  -- a reason whose named replacement cannot be resolved falls back to no_longer_relevant
  update sb563_backfill set reason = 'no_longer_relevant' where reason <> 'no_longer_relevant' and repl is null;
  select count(*) into v_expected from sb563_backfill;

  update public.work_items w
     set status = 'cancelled',
         cancel_reason = b.reason,
         cancel_replaced_by = case when b.reason = 'no_longer_relevant' then null else b.repl end,
         cancel_note = 'Backfilled from meta.closure_reason: ' || b.cr
                       || coalesce('; superseded_by: ' || (w.meta->>'superseded_by'), '')
                       || coalesce('; duplicate_of: ' || (w.meta->>'duplicate_of'), ''),
         cancelled_by = 'Jason',
         cancelled_at = coalesce(b.completed_at, now())
    from sb563_backfill b
   where w.id = b.id;
  get diagnostics v_done = row_count;

  select count(*) into v_left from public.work_items
   where status = 'done' and meta ? 'closure_reason' and meta->>'closure_reason' !~* '^fixed:';
  if v_done <> v_expected or v_left <> 0 then
    raise exception 'SB-563 backfill: converted % of %, % non-delivery done rows left', v_done, v_expected, v_left;
  end if;
  raise notice 'SB-563 backfill: % rows converted', v_done;
  perform set_config('supabrain.cancel_backfill', 'off', true);
end
$backfill$;

-- Assertions -------------------------------------------------------------------
do $chk$
declare
  v_trg text[];
begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.work_items'::regclass
                  and conname = 'work_items_status_check' and pg_get_constraintdef(oid) like '%cancelled%') then
    raise exception 'A1: status check must admit cancelled';
  end if;
  select array_agg(tgname order by tgname) into v_trg from pg_trigger
   where tgrelid = 'public.work_items'::regclass and not tgisinternal
     and tgname in ('trg_cancellation', 'trg_enforce_authority_governance');
  -- BEFORE triggers fire in name order, so trg_cancellation runs before GOV-001.
  if v_trg is distinct from array['trg_cancellation', 'trg_enforce_authority_governance']::text[] then
    raise exception 'A2: trg_cancellation must exist and fire before trg_enforce_authority_governance';
  end if;
  if exists (select 1 from pg_proc where oid in ('public.generate_daily_audit(uuid,uuid,date,uuid)'::regprocedure,
                                                 'public.crm_steward_scheduled(text)'::regprocedure,
                                                 'public.sync_school_assignment_to_fam(uuid)'::regprocedure)
              and (prosrc ~ 'NOT IN \(''done'',''backlog''\)' or prosrc ~ 'status != ''done''' or prosrc ~ 'status <> ''done''')) then
    raise exception 'A3: a patched function still treats not-done as open';
  end if;
  if has_function_privilege('anon', 'public.cancel_work_item(uuid,text,text,text,text)', 'execute')
     or has_function_privilege('anon', 'public.reopen_work_item(uuid,text,text)', 'execute')
     or exists (select 1 from pg_proc where oid in ('public.cancel_work_item(uuid,text,text,text,text)'::regprocedure,
                                                    'public.reopen_work_item(uuid,text,text)'::regprocedure,
                                                    'public.enforce_cancellation()'::regprocedure)
                 and (prosecdef or not proconfig @> array['search_path=""'])) then
    raise exception 'A4: RPCs and trigger must be invoker, search_path pinned, closed to anon';
  end if;
  if not exists (select 1 from public.authority_action_map where action_category = 'ticket_cancellation') then
    raise exception 'A5: authority_action_map entry missing';
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.governance_audit'::regclass
                  and conname = 'governance_audit_decision_check'
                  and pg_get_constraintdef(oid) like '%cancelled%' and pg_get_constraintdef(oid) like '%reopened%') then
    raise exception 'A6: governance_audit must accept cancelled and reopened';
  end if;
  if exists (select 1 from public.work_items where status = 'cancelled'
              and (cancelled_by is distinct from 'Jason' or cancel_reason is null)) then
    raise exception 'A7: backfilled rows must carry reason and actor';
  end if;
end
$chk$;
