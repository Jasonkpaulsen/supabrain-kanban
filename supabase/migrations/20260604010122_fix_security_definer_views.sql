-- SEC-002: Recreate SECURITY DEFINER views as SECURITY INVOKER

-- kanban_board_view
DROP VIEW IF EXISTS kanban_board_view;
CREATE VIEW kanban_board_view WITH (security_invoker = true) AS
SELECT w.id,
    w.project_id,
    w.user_id,
    w.title,
    w.description,
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
    p.name AS project_name,
    p.icon AS project_icon,
    a.name AS agent_name,
    a.icon AS agent_icon,
    a.status AS agent_status,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name, 'color', l.color))
           FROM work_item_labels wl
             JOIN labels l ON l.id = wl.label_id
          WHERE wl.work_item_id = w.id), '[]'::jsonb) AS labels,
    ( SELECT count(*)
           FROM work_item_comments c
          WHERE c.work_item_id = w.id) AS comment_count
   FROM work_items w
     JOIN projects p ON p.id = w.project_id
     LEFT JOIN agents a ON a.id = w.assigned_agent_id;

-- vw_pipeline_integrity_violations
DROP VIEW IF EXISTS vw_pipeline_integrity_violations;
CREATE VIEW vw_pipeline_integrity_violations WITH (security_invoker = true) AS
WITH gen AS (
    SELECT resume_generations.job_application_id,
        count(*) AS gen_count
    FROM resume_generations
    WHERE resume_generations.job_application_id IS NOT NULL
    GROUP BY resume_generations.job_application_id
)
SELECT ja.id,
    ja.company,
    ja.title,
    ja.status,
    ja.decision,
    ja.match_quality,
    ja.applied_at,
    ja.resume_file,
    COALESCE(g.gen_count, 0::bigint) AS resume_generations_count,
    array_remove(ARRAY[
        CASE WHEN ja.status = 'applied' AND COALESCE(g.gen_count, 0::bigint) = 0 THEN 'R1: status=applied without resume_generations row' ELSE NULL END,
        CASE WHEN ja.status = 'applied' AND ja.resume_file IS NULL THEN 'R2a: status=applied without resume_file logged' ELSE NULL END,
        CASE WHEN ja.status = 'applied' AND ja.applied_at IS NULL THEN 'R2b: status=applied without applied_at timestamp' ELSE NULL END,
        CASE WHEN ja.status = 'applied' AND ja.resume_file IS NOT NULL AND NOT public.fn_company_resume_match(ja.resume_file, ja.company) THEN 'R3: resume_file (' || ja.resume_file || ') does not match target (' || ja.company || ')' ELSE NULL END,
        CASE WHEN ja.decision = 'apply' AND ja.status = 'new' AND ja.score IS NOT NULL AND ja.score < 3.0 THEN 'R4: decision=apply with score < 3.0 — below v3 threshold' ELSE NULL END,
        CASE WHEN ja.decision = 'skip' AND (ja.status <> ALL (ARRAY['skipped', 'rejected', 'withdrawn'])) THEN 'R5: decision=skip but status not in (skipped/rejected/withdrawn)' ELSE NULL END,
        CASE WHEN ja.decision = ANY (ARRAY['MODERATE_MATCH', 'WEAK_MATCH', 'STRONG_MATCH', 'applied']) THEN 'R6: legacy match label in decision column (belongs in match_quality; decision should be apply/review/skip)' ELSE NULL END,
        CASE WHEN ja.score IS NOT NULL AND ja.match_quality IS NOT NULL AND (ja.score >= 4.0 AND ja.match_quality <> 'STRONG_MATCH' OR ja.score >= 3.0 AND ja.score < 4.0 AND ja.match_quality <> 'MODERATE_MATCH' OR ja.score < 3.0 AND ja.match_quality <> 'WEAK_MATCH') THEN 'R7: match_quality (' || ja.match_quality || ') does not match score band (' || ja.score::text || ')' ELSE NULL END
    ], NULL) AS violations
FROM job_applications ja
LEFT JOIN gen g ON g.job_application_id = ja.id;;
