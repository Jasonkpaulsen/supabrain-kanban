
-- FAM-011: Wire School Monitor -> Family Care Manager.
-- Idempotent handoff: school_assignments -> FAM board reminders (work_items) + family_events.
-- No change to School Monitor scraping scope. All functions SECURITY DEFINER w/ pinned search_path.

CREATE OR REPLACE FUNCTION public.sync_school_assignment_to_fam(p_assignment_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $fn$
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
          meta         = jsonb_set(COALESCE(meta,'{}'::jsonb), '{auto_resolved}',
                           to_jsonb(format('assignment status=%s on %s', a.status, CURRENT_DATE::text)))
      WHERE id = v_wi_id;
    END IF;
  END IF;

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
$fn$;

-- Trigger glue: fire the handoff whenever School Monitor writes/updates an assignment.
CREATE OR REPLACE FUNCTION public.tg_school_assignment_to_fam()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $tg$
BEGIN
  PERFORM public.sync_school_assignment_to_fam(NEW.id);
  RETURN NEW;
END;
$tg$;

DROP TRIGGER IF EXISTS trg_school_assignment_to_fam ON public.school_assignments;
CREATE TRIGGER trg_school_assignment_to_fam
AFTER INSERT OR UPDATE OF status, due_date, title, class_name, child_name, teacher, classroom_url, archived
ON public.school_assignments
FOR EACH ROW
EXECUTE FUNCTION public.tg_school_assignment_to_fam();

-- One-shot backfill for any rows that predate the wiring.
CREATE OR REPLACE FUNCTION public.backfill_school_assignments_to_fam()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $bf$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN SELECT id FROM public.school_assignments LOOP
    PERFORM public.sync_school_assignment_to_fam(r.id);
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$bf$;

-- Keep these internal (consistent with the SB-237 security posture): not public RPCs.
REVOKE ALL ON FUNCTION public.sync_school_assignment_to_fam(uuid)   FROM PUBLIC;
REVOKE ALL ON FUNCTION public.backfill_school_assignments_to_fam()  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.tg_school_assignment_to_fam()         FROM PUBLIC;
;
