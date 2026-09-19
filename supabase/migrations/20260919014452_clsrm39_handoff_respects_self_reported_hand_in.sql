-- CLSRM-39 part 2: make the FAM board reminder read the self-report.
--
-- Without this the columns from part 1 change nothing a parent sees, and the
-- board keeps nagging about physically handed-in work — the actual complaint.
--
-- What changes, and what deliberately does not:
--   * v_actionable is UNCHANGED. Whether an item is on the board stays Google's
--     call. A self-report cannot remove a reminder, because that is the failure
--     direction CLSRM-26 named unrecoverable.
--   * reported_only  -> priority drops high -> medium, title says so. The nag stops.
--   * disputed       -> priority stays high, title says the teacher has not
--     recorded it after N days. The claim gets LOUDER with age, not quieter.
--   * agreed         -> auto-resolve, exactly as before.
--
-- Read back from the catalog and rewritten in place rather than re-typed, so
-- nothing else in the body can drift (the technique SB-439 used).

do $$
declare def text;
begin
  select pg_get_functiondef('public.sync_school_assignment_to_fam(uuid)'::regprocedure) into def;

  -- 1. declare the two locals we need
  def := replace(def,
    '  v_fe_id       uuid;',
    '  v_fe_id       uuid;' || chr(10) ||
    '  v_reported    boolean;' || chr(10) ||
    '  v_disputed    boolean;');

  -- 2. derive them next to v_actionable, from the same row
  def := replace(def,
    '    SELECT id, status INTO v_wi_id, v_wi_status',
    '    -- CLSRM-39: the child''s claim, and whether the teacher has ignored it long enough to matter.' || chr(10) ||
    '    v_reported := a.turned_in_reported_at IS NOT NULL;' || chr(10) ||
    '    v_disputed := v_reported AND a.turned_in_reported_at' || chr(10) ||
    '                  < now() - make_interval(days => public.turned_in_grace_days());' || chr(10) ||
    '' || chr(10) ||
    '    SELECT id, status INTO v_wi_id, v_wi_status');

  -- 3. annotate the title and re-weight the priority
  def := replace(def,
    '      v_title    := format(''[School] %s — %s: %s'', a.child_name, a.class_name, a.title);',
    '      v_title    := format(''[School] %s — %s: %s'', a.child_name, a.class_name, a.title)' || chr(10) ||
    '                    || CASE' || chr(10) ||
    '                         WHEN v_disputed THEN format('' (reported turned in %s — teacher has not recorded it after %s days)'',' || chr(10) ||
    '                                                     a.turned_in_reported_at::date, current_date - a.turned_in_reported_at::date)' || chr(10) ||
    '                         WHEN v_reported THEN format('' (reported turned in %s)'', a.turned_in_reported_at::date)' || chr(10) ||
    '                         ELSE '''' END;');

  def := replace(def,
    '      v_priority := CASE WHEN a.status IN (''missing'',''late'') OR v_overdue THEN ''high'' ELSE ''medium'' END;',
    '      -- CLSRM-39: an unverified claim quiets the board; an ignored one re-escalates.' || chr(10) ||
    '      v_priority := CASE' || chr(10) ||
    '                      WHEN v_disputed THEN ''high''' || chr(10) ||
    '                      WHEN v_reported THEN ''medium''' || chr(10) ||
    '                      WHEN a.status IN (''missing'',''late'') OR v_overdue THEN ''high''' || chr(10) ||
    '                      ELSE ''medium'' END;');

  -- 4. carry the claim onto the work item so the board can show it without a join
  def := replace(def,
    '            ''assignment_status'', a.status,',
    '            ''assignment_status'', a.status,' || chr(10) ||
    '            ''turned_in_reported_at'', a.turned_in_reported_at,' || chr(10) ||
    '            ''turned_in_reported_by'', a.turned_in_reported_by,' || chr(10) ||
    '            ''turned_in_method'', a.turned_in_method,');

  def := replace(def,
    '        meta        = jsonb_set(COALESCE(meta,''{}''::jsonb), ''{assignment_status}'', to_jsonb(a.status))',
    '        meta        = jsonb_set(' || chr(10) ||
    '                        jsonb_set(' || chr(10) ||
    '                          jsonb_set(COALESCE(meta,''{}''::jsonb), ''{assignment_status}'', to_jsonb(a.status)),' || chr(10) ||
    '                          ''{turned_in_reported_at}'', to_jsonb(a.turned_in_reported_at)),' || chr(10) ||
    '                        ''{reconciliation_state}'',' || chr(10) ||
    '                        to_jsonb(CASE WHEN v_disputed THEN ''disputed''' || chr(10) ||
    '                                      WHEN v_reported THEN ''reported_only''' || chr(10) ||
    '                                      ELSE ''unreported'' END))');

  execute def;
end $$;

do $$
declare src text;
begin
  select prosrc into src from pg_proc
   where oid='public.sync_school_assignment_to_fam(uuid)'::regprocedure;

  if position('turned_in_grace_days' in src) = 0 then
    raise exception 'CLSRM-39: the handoff does not consult the grace window — rewrite did not apply';
  end if;
  if position('v_disputed' in src) = 0 or position('reported turned in' in src) = 0 then
    raise exception 'CLSRM-39: the handoff does not annotate a reported hand-in';
  end if;
  if position('reconciliation_state' in src) = 0 then
    raise exception 'CLSRM-39: the handoff does not stamp reconciliation_state on the reminder';
  end if;
  -- the guarantee that must survive: a claim cannot take an item off the board
  if position('v_actionable := (NOT COALESCE(a.archived,false))' in src) = 0 then
    raise exception 'CLSRM-39: v_actionable was altered — a self-report must never suppress a reminder';
  end if;
  if position('turned_in' in split_part(src, 'v_actionable :=', 2)) > 0
     and position('turned_in' in split_part(split_part(src, 'v_actionable :=', 2), ';', 1)) > 0 then
    raise exception 'CLSRM-39: the self-report leaked into the actionable test';
  end if;
  if (select prosecdef from pg_proc
      where oid='public.sync_school_assignment_to_fam(uuid)'::regprocedure) is not true then
    raise exception 'CLSRM-39: sync_school_assignment_to_fam lost SECURITY DEFINER';
  end if;
end $$;;
