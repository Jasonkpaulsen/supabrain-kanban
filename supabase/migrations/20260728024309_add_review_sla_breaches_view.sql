
-- SB-254: Review-queue dwell SLA + auto-escalation view
-- Soft breach: 48h in review | Hard breach: 72h in review

-- 1. Add optional breach timestamp column
ALTER TABLE public.work_items
  ADD COLUMN IF NOT EXISTS review_sla_breached_at timestamptz;

COMMENT ON COLUMN public.work_items.review_sla_breached_at
  IS 'Set when item first crosses 48h in review status; cleared when it leaves review.';

-- 2. Create SLA breach view
CREATE OR REPLACE VIEW public.v_review_sla_breaches AS
SELECT
  wi.id,
  wi.ticket_code,
  wi.title,
  wi.assignee,
  p.project_key,
  wi.user_id,
  wi.review_entered_at,
  ROUND(EXTRACT(EPOCH FROM (NOW() - wi.review_entered_at)) / 3600, 1) AS hours_in_review,
  CASE
    WHEN EXTRACT(EPOCH FROM (NOW() - wi.review_entered_at)) / 3600 >= 72 THEN 'hard'
    ELSE 'soft'
  END AS breach_level
FROM public.work_items wi
JOIN public.projects p ON p.id = wi.project_id
WHERE wi.status = 'review'
  AND wi.review_entered_at IS NOT NULL
  AND EXTRACT(EPOCH FROM (NOW() - wi.review_entered_at)) / 3600 >= 48
  AND p.archived = false
  AND p.automation_status != 'paused';

COMMENT ON VIEW public.v_review_sla_breaches
  IS 'Work items in review past SLA thresholds (soft=48h, hard=72h). User-scoped via user_id column.';

-- 3. Backfill review_sla_breached_at for items already past 48h
UPDATE public.work_items
SET review_sla_breached_at = review_entered_at + INTERVAL '48 hours'
WHERE status = 'review'
  AND review_entered_at IS NOT NULL
  AND EXTRACT(EPOCH FROM (NOW() - review_entered_at)) / 3600 >= 48
  AND review_sla_breached_at IS NULL;
;
