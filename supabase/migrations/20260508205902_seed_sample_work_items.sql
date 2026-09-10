
-- Step 7: Seed sample work items across several projects
-- Uses real project IDs from the existing projects table

DO $$
DECLARE
  v_user_id uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';
  v_wi1 uuid; v_wi2 uuid; v_wi3 uuid; v_wi4 uuid; v_wi5 uuid;
  v_wi6 uuid; v_wi7 uuid; v_wi8 uuid; v_wi9 uuid; v_wi10 uuid;
  v_lbl_bug uuid; v_lbl_feature uuid; v_lbl_urgent uuid; v_lbl_research uuid; v_lbl_blocked uuid;
BEGIN
  -- Get label IDs
  SELECT id INTO v_lbl_bug FROM public.labels WHERE user_id = v_user_id AND name = 'Bug';
  SELECT id INTO v_lbl_feature FROM public.labels WHERE user_id = v_user_id AND name = 'Feature';
  SELECT id INTO v_lbl_urgent FROM public.labels WHERE user_id = v_user_id AND name = 'Urgent';
  SELECT id INTO v_lbl_research FROM public.labels WHERE user_id = v_user_id AND name = 'Research';
  SELECT id INTO v_lbl_blocked FROM public.labels WHERE user_id = v_user_id AND name = 'Blocked';

  -- Job Search Pipeline work items
  INSERT INTO public.work_items (user_id, project_id, title, description, status, priority, sort_order, source_table, source_id)
  VALUES (v_user_id, '219c49e4-9953-41a8-a806-629e7dab00a5', 'Review high-score pending applications', 'Go through pending jobs with score >= 4.0 and make apply/skip decisions', 'todo', 'high', 0, 'job_applications', null)
  RETURNING id INTO v_wi1;

  INSERT INTO public.work_items (user_id, project_id, title, description, status, priority, sort_order)
  VALUES (v_user_id, '219c49e4-9953-41a8-a806-629e7dab00a5', 'Update resume for healthcare IT roles', 'Tailor resume bullet points for Director-level healthcare technology positions', 'in_progress', 'high', 0)
  RETURNING id INTO v_wi2;

  INSERT INTO public.work_items (user_id, project_id, title, description, status, priority, sort_order)
  VALUES (v_user_id, '219c49e4-9953-41a8-a806-629e7dab00a5', 'Set up LinkedIn job alerts for CIDO roles', 'Configure automated alerts for Chief Information/Data Officer positions', 'done', 'medium', 0)
  RETURNING id INTO v_wi3;

  -- Open Brain project work items
  INSERT INTO public.work_items (user_id, project_id, title, description, status, priority, sort_order)
  VALUES (v_user_id, 'c89d95d1-e61f-4926-84f0-7b41bb581483', 'Fix RLS policies after security audit', 'Enable RLS on all public tables, drop dangerous anon policies, revoke anon function access', 'done', 'critical', 0)
  RETURNING id INTO v_wi4;

  INSERT INTO public.work_items (user_id, project_id, title, description, status, priority, sort_order)
  VALUES (v_user_id, 'c89d95d1-e61f-4926-84f0-7b41bb581483', 'Design Kanban work management schema', 'Create tables for work_items, labels, comments to power a JIRA-like board', 'in_progress', 'high', 0)
  RETURNING id INTO v_wi5;

  INSERT INTO public.work_items (user_id, project_id, title, description, status, priority, sort_order)
  VALUES (v_user_id, 'c89d95d1-e61f-4926-84f0-7b41bb581483', 'Set up automated database backups', 'GitHub Actions workflow for nightly pg_dump to private repo', 'done', 'high', 1)
  RETURNING id INTO v_wi6;

  -- BigCat Agency work items
  INSERT INTO public.work_items (user_id, project_id, title, description, status, priority, sort_order)
  VALUES (v_user_id, 'a1b2c3d4-0001-0001-0001-000000000001', 'Finalize pricing tiers for AI audit service', 'Define starter/pro/enterprise pricing based on competitor analysis', 'todo', 'high', 0)
  RETURNING id INTO v_wi7;

  INSERT INTO public.work_items (user_id, project_id, title, description, status, priority, sort_order)
  VALUES (v_user_id, 'a1b2c3d4-0001-0001-0001-000000000001', 'Draft case study from first demo engagement', 'Write up results and ROI from the AI audit demo project', 'backlog', 'medium', 0)
  RETURNING id INTO v_wi8;

  -- Chromatic Shadows work items
  INSERT INTO public.work_items (user_id, project_id, title, description, status, priority, sort_order)
  VALUES (v_user_id, 'a823caba-9416-4bdf-9bc0-86b3066f1e00', 'Fix pip dot rendering in character sheet', 'CSS pips not filling correctly on some attribute tracks', 'todo', 'medium', 0)
  RETURNING id INTO v_wi9;

  INSERT INTO public.work_items (user_id, project_id, title, description, status, priority, sort_order)
  VALUES (v_user_id, 'a823caba-9416-4bdf-9bc0-86b3066f1e00', 'Add weapon damage roll buttons', 'Wire weapon attack buttons to roll templates with Strength/Agility modifiers', 'backlog', 'low', 0)
  RETURNING id INTO v_wi10;

  -- Assign labels to some work items
  INSERT INTO public.work_item_labels (work_item_id, label_id) VALUES
    (v_wi1, v_lbl_urgent),
    (v_wi2, v_lbl_feature),
    (v_wi4, v_lbl_bug),
    (v_wi4, v_lbl_urgent),
    (v_wi5, v_lbl_feature),
    (v_wi7, v_lbl_research),
    (v_wi9, v_lbl_bug);

  -- Add a couple sample comments
  INSERT INTO public.work_item_comments (work_item_id, user_id, body) VALUES
    (v_wi4, v_user_id, 'Completed: enabled RLS on employer_details, dropped anon policies, revoked anon function access'),
    (v_wi5, v_user_id, 'Schema designed with 5 tables: projects (existing), work_items, labels, work_item_labels, work_item_comments'),
    (v_wi6, v_user_id, 'Workflow running nightly at 3am UTC. First successful backup confirmed.');
END;
$$;
;
