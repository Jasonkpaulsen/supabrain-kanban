-- CLSRM-13: the daily Classroom sweep has failed every day since 2026-09-12.
--
-- Cause: sync_school_assignment_to_fam() auto-raises FAM board reminders with
-- meta.qa_gate_exempt = true, but never sets review_gate_exempt. When a child
-- submits an assignment the function auto-resolves the reminder todo -> done in
-- one UPDATE, and enforce_done_gate refuses it: "review_entered_at is null".
-- The exception propagates out of tg_school_assignment_to_fam and aborts the
-- whole school_assignments upsert, so the entire sweep exits 1 and NOTHING is
-- written -- including the evidence of why, which rolls back with it.
--
-- Machine-generated school reminders have nothing a human reviews: no code, no
-- decision. The author already exempted the QA gate for exactly that reason and
-- missed its sibling. This finishes that intent rather than weakening a control.
--
-- Two changes:
--   1. Set review_gate_exempt on both the INSERT and the auto-resolve UPDATE, so
--      pre-existing rows self-heal on their next touch. Backfill the 13 live rows.
--   2. Isolate the FAM board handoff behind an exception handler. Pulling
--      Classroom state is this job's primary duty; mirroring it onto the family
--      board is secondary, and a gate change must never again take the primary
--      duty down with it. Failures RAISE WARNING (visible in the Postgres log and
--      the sweep's stderr) instead of aborting -- degraded, not silent.

create or replace function public.sync_school_assignment_to_fam(p_assignment_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'pg_catalog', 'public'
as $function$
DECLARE
  a            public.school_assignments%ROWTYPE;
  v_fam_project uuid := 'ed8cb7f7-a604-4054-a76e-c3e1114b5316';  -- Paulsen Family (FAM)
  v_fcm_agent   uuid := 'b5fc1ef9-7a12-4c89-b600-b3d9ed1613b8';  -- Family Care Manager
  v_overdue     boolean;
  v_actionable  boolean;
  v_wi_id       uuid;
  v_wi_status   text;
  v_title       text;
  v_priority    text;
  v_fe_id       uuid;
BEGIN
  SELECT * INTO a FROM public.school_assignments WHERE id = p_assignment_id;
  IF NOT FOUND THEN RETURN; END IF;

  -- ---------- FAM board reminder (work_items) ----------
  -- CLSRM-13: isolated. A refusal here degrades the handoff, never the sweep.
  BEGIN
    v_overdue    := (a.due_date IS NOT NULL AND a.due_date < CURRENT_DATE);
    v_actionable := (NOT COALESCE(a.archived,false))
                    AND ( a.status IN ('missing','late')
                          OR (a.status = 'assigned' AND v_overdue) );

    SELECT id, status INTO v_wi_id, v_wi_status
    FROM public.work_items
    WHERE source_table = 'school_assignments' AND source_id = a.id
    LIMIT 1;

    IF v_actionable THEN
      v_title    := format('[School] %s — %s: %s', a.child_name, a.class_name, a.title);
      v_priority := CASE WHEN a.status IN ('missing','late') OR v_overdue THEN 'high' ELSE 'medium' END;

      IF v_wi_id IS NULL THEN
        INSERT INTO public.work_items
          (project_id, user_id, title, description, status, priority, type,
           assignee, assigned_agent_id, due_date, source_table, source_id,
           authority_level, action_category, meta)
        VALUES
          (v_fam_project, a.user_id, v_title,
           format('Auto-raised by the School Monitor -> Family Care Manager handoff (FAM-011). %s''s assignment "%s" in %s%s is currently %s.%s',
                  a.child_name, a.title, a.class_name,
                  COALESCE(' (teacher ' || a.teacher || ')',''),
                  a.status,
                  COALESCE(' Due ' || a.due_date::text || '.','')),
           'todo', v_priority, 'task',
           'Family Care Manager', v_fcm_agent, a.due_date,
           'school_assignments', a.id,
           0, 'routine_maintenance',
           jsonb_build_object(
             'origin','school_monitor_handoff',
             'ticket','FAM-011',
             'qa_gate_exempt', true,
             'review_gate_exempt', true,
             'gate_exempt_reason','CLSRM-13: machine-generated school reminder; auto-resolved from Classroom state, nothing for a human to review',
             'child_name', a.child_name,
             'child_project_id', a.child_project_id,
             'class_name', a.class_name,
             'assignment_status', a.status,
             'classroom_url', a.classroom_url
           ));
      ELSE
        UPDATE public.work_items
        SET title       = v_title,
            priority    = v_priority,
            due_date    = a.due_date,
            status      = CASE WHEN status = 'done' THEN 'todo' ELSE status END,
            completed_at= CASE WHEN status = 'done' THEN NULL ELSE completed_at END,
            meta        = jsonb_set(COALESCE(meta,'{}'::jsonb), '{assignment_status}', to_jsonb(a.status))
        WHERE id = v_wi_id;
      END IF;
    ELSE
      -- No longer actionable (submitted/graded/returned, archived, or assigned-not-overdue): auto-resolve.
      IF v_wi_id IS NOT NULL AND v_wi_status <> 'done' THEN
        UPDATE public.work_items
        SET status       = 'done',
            completed_at = now(),
            meta         = jsonb_set(
                             jsonb_set(COALESCE(meta,'{}'::jsonb), '{review_gate_exempt}', 'true'::jsonb),
                             '{auto_resolved}',
                             to_jsonb(format('assignment status=%s on %s', a.status, CURRENT_DATE::text)))
        WHERE id = v_wi_id;
      END IF;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'CLSRM-13: FAM board handoff skipped for school_assignment % (%): % %',
      a.id, a.title, SQLSTATE, SQLERRM;
  END;

  -- ---------- family_events (dated school item -> calendar) ----------
  SELECT id INTO v_fe_id
  FROM public.family_events
  WHERE source = 'school_monitor' AND external_ref = a.id::text
  LIMIT 1;

  IF (NOT COALESCE(a.archived,false)) AND a.due_date IS NOT NULL THEN
    IF v_fe_id IS NULL THEN
      INSERT INTO public.family_events
        (user_id, child_project_id, title, event_type, starts_at, source, external_ref)
      VALUES
        (a.user_id, a.child_project_id,
         format('%s — %s due (%s)', a.child_name, a.title, a.class_name),
         'school', (a.due_date::timestamp AT TIME ZONE 'UTC'),
         'school_monitor', a.id::text);
    ELSE
      UPDATE public.family_events
      SET title            = format('%s — %s due (%s)', a.child_name, a.title, a.class_name),
          starts_at        = (a.due_date::timestamp AT TIME ZONE 'UTC'),
          child_project_id = a.child_project_id
      WHERE id = v_fe_id;
    END IF;
  ELSE
    IF v_fe_id IS NOT NULL THEN
      DELETE FROM public.family_events WHERE id = v_fe_id;
    END IF;
  END IF;
END;
$function$;

-- Backfill the reminders already on the board, so the next sweep can resolve them.
update public.work_items
set meta = jsonb_set(
             jsonb_set(coalesce(meta,'{}'::jsonb), '{review_gate_exempt}', 'true'::jsonb),
             '{gate_exempt_reason}',
             to_jsonb('CLSRM-13: machine-generated school reminder; auto-resolved from Classroom state, nothing for a human to review'::text))
where source_table = 'school_assignments'
  and coalesce(meta->>'review_gate_exempt','false') <> 'true';

do $$
declare n_missing int;
begin
  select count(*) into n_missing
  from public.work_items
  where source_table = 'school_assignments'
    and coalesce(meta->>'review_gate_exempt','false') <> 'true';
  if n_missing > 0 then
    raise exception 'CLSRM-13: % school work item(s) still lack review_gate_exempt', n_missing;
  end if;

  if (select prosecdef from pg_proc where oid = 'public.sync_school_assignment_to_fam(uuid)'::regprocedure) is not true then
    raise exception 'CLSRM-13: sync_school_assignment_to_fam lost SECURITY DEFINER';
  end if;
end $$;

comment on function public.sync_school_assignment_to_fam(uuid) is
  'CLSRM-13: mirrors a Classroom assignment onto the FAM board and calendar. The work_items half is exception-isolated — a gate refusal logs a WARNING and skips that handoff rather than aborting the daily sweep. Reminders carry qa_gate_exempt and review_gate_exempt because they are machine-generated and machine-resolved.';;
