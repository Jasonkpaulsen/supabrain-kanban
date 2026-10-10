-- ADR-FLOW-003 §4.3, §4.5, §5 — the sweep.
create or replace function public.archive_work_items(
  p_dry_run boolean default true,
  p_days integer default 14,
  p_force boolean default false
)
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
  -- the global default -- the candidate set spans 11 projects.
  select array_agg(w.id) into v_ids
  from work_items w
  join projects pr on pr.id = w.project_id
  where w.status = 'done'
    and w.archived = false
    and w.completed_at is not null
    and w.completed_at < now() - make_interval(
          days => coalesce((pr.meta->>'archive_after_days')::int, p_days))
    and not exists (
      select 1 from work_items c
      where c.parent_id = w.id and c.status <> 'done'
    );

  v_count := coalesce(array_length(v_ids, 1), 0);

  -- §5 anomaly guard. cron.job_run_details shows 23% of runs on this project fail;
  -- a sweep that fails silently is the default outcome here, not the exception.
  select percentile_cont(0.5) within group (order by (meta->>'count')::numeric)
    into v_median
  from activity_log
  where target_table = 'work_items'
    and meta->>'archive_run_id' is not null
    and meta->>'mode' = 'live';

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

  -- §4.5 ONE summary row per run, not one per item: activity_log holds ~330 rows
  -- lifetime and a per-row dump would nearly double the table's entire history.
  select project_id, user_id into v_project_id, v_user_id
  from work_items where id = v_ids[1];

  insert into activity_log (project_id, user_id, agent_name, action, target_table, target_id, summary, meta)
  values (
    v_project_id, v_user_id, 'archive_work_items', 'archived', 'work_items', null,
    format('Archived %s done work items older than %s days (run %s).', v_count, p_days, v_run_id),
    jsonb_build_object(
      'archive_run_id', v_run_id::text,
      'mode', 'live',
      'count', v_count,
      'days', p_days,
      'forced', p_force,
      'ids', to_jsonb(v_ids)
    )
  );

  return jsonb_build_object('run_id', v_run_id, 'mode', 'live', 'count', v_count, 'forced', p_force);
end;
$$;

comment on function public.archive_work_items(boolean, integer, boolean) is
  'ADR-FLOW-003 sweep. Idempotent (archived = false is in the predicate). Dry-run by default. Stamps meta.archive_run_id and writes one summary activity_log row so rollback by run is possible. p_force bypasses the anomaly guard for an explicitly approved run.';

-- §5 manual archive / restore.
create or replace function public.set_work_item_archived(
  p_item_id uuid,
  p_archived boolean
)
returns work_items
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row work_items;
begin
  update work_items
  set archived = p_archived,
      archived_at = case when p_archived then now() else null end
  where id = p_item_id
  returning * into v_row;

  if not found then
    raise exception 'work item % not found', p_item_id;
  end if;

  return v_row;
end;
$$;

comment on function public.set_work_item_archived(uuid, boolean) is
  'ADR-FLOW-003 manual archive/restore. Manual archives carry no archive_run_id, so a rollback by run can never catch them.';

grant execute on function public.set_work_item_archived(uuid, boolean) to authenticated;
grant execute on function public.archive_work_items(boolean, integer, boolean) to authenticated;;
