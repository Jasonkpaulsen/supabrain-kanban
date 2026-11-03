
-- SB-230: Biweekly backlog grooming cadence + soft intake gate
-- 1. Grooming cadence tracking table
CREATE TABLE IF NOT EXISTS grooming_cadence (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES projects(id),
  groomed_at timestamptz NOT NULL DEFAULT now(),
  groomed_by text NOT NULL DEFAULT 'PE',
  items_reviewed int NOT NULL DEFAULT 0,
  items_promoted int NOT NULL DEFAULT 0,
  items_deferred int NOT NULL DEFAULT 0,
  items_closed int NOT NULL DEFAULT 0,
  notes text,
  meta jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now()
);

-- Index for lookups by project + recency
CREATE INDEX idx_grooming_cadence_project ON grooming_cadence(project_id, groomed_at DESC);

-- 2. View: v_backlog_grooming_queue
-- Surfaces ungroomed backlog items sorted by age, priority, project
-- "Ungroomed" = backlog items created/updated after the project's last groom session
-- CIP project sorts first
CREATE OR REPLACE VIEW v_backlog_grooming_queue AS
WITH last_groom AS (
  SELECT project_id, MAX(groomed_at) AS last_groomed_at
  FROM grooming_cadence
  GROUP BY project_id
),
priority_rank AS (
  SELECT unnest(ARRAY['critical','high','medium','low']) AS p,
         generate_series(1,4) AS p_rank
)
SELECT
  wi.id,
  wi.ticket_code,
  wi.title,
  wi.type,
  wi.priority,
  wi.status,
  wi.assignee,
  wi.created_at,
  wi.updated_at,
  p.project_key,
  p.name AS project_name,
  lg.last_groomed_at,
  EXTRACT(DAY FROM now() - wi.created_at)::int AS age_days,
  CASE WHEN p.project_key = 'CIP' THEN 0 ELSE 1 END AS project_sort,
  COALESCE(pr.p_rank, 5) AS priority_sort,
  CASE
    WHEN lg.last_groomed_at IS NULL THEN true
    WHEN wi.created_at > lg.last_groomed_at THEN true
    WHEN wi.updated_at > lg.last_groomed_at THEN true
    ELSE false
  END AS needs_grooming
FROM work_items wi
JOIN projects p ON p.id = wi.project_id
LEFT JOIN last_groom lg ON lg.project_id = wi.project_id
LEFT JOIN priority_rank pr ON pr.p = wi.priority
WHERE wi.status = 'backlog'
  AND p.archived = false
ORDER BY
  project_sort,                    -- CIP first
  CASE
    WHEN lg.last_groomed_at IS NULL THEN 0
    WHEN wi.created_at > lg.last_groomed_at THEN 0
    ELSE 1
  END,                             -- ungroomed first
  COALESCE(pr.p_rank, 5),         -- higher priority first
  wi.created_at ASC;              -- oldest first

-- 3. View: v_grooming_schedule — shows next groom dates per project
CREATE OR REPLACE VIEW v_grooming_schedule AS
WITH last_groom AS (
  SELECT project_id, MAX(groomed_at) AS last_groomed_at
  FROM grooming_cadence
  GROUP BY project_id
)
SELECT
  p.id AS project_id,
  p.project_key,
  p.name AS project_name,
  lg.last_groomed_at,
  CASE
    WHEN lg.last_groomed_at IS NULL THEN now()
    ELSE lg.last_groomed_at + interval '14 days'
  END AS next_groom_due,
  CASE
    WHEN lg.last_groomed_at IS NULL THEN true
    WHEN now() >= lg.last_groomed_at + interval '14 days' THEN true
    ELSE false
  END AS groom_overdue,
  COUNT(wi.id) AS backlog_count
FROM projects p
LEFT JOIN last_groom lg ON lg.project_id = p.id
LEFT JOIN work_items wi ON wi.project_id = p.id AND wi.status = 'backlog'
WHERE p.archived = false
GROUP BY p.id, p.project_key, p.name, lg.last_groomed_at
HAVING COUNT(wi.id) > 0
ORDER BY
  CASE WHEN p.project_key = 'CIP' THEN 0 ELSE 1 END,
  CASE WHEN lg.last_groomed_at IS NULL THEN '1970-01-01'::timestamptz ELSE lg.last_groomed_at END ASC;

-- 4. Enable RLS on grooming_cadence
ALTER TABLE grooming_cadence ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users manage own grooming records" ON grooming_cadence
  FOR ALL USING (
    project_id IN (SELECT id FROM projects WHERE user_id = auth.uid())
  );
;
