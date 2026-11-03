
-- SB-272: Reconcile stale qa_status values to match test_cases ground truth.
-- 8 items marked 'tested' with no test_cases → set to 'untested'
-- 2 items marked 'untested' with test_cases → set to 'tested'

-- Fix items marked 'tested' but with no linked test_cases
UPDATE public.work_items
SET qa_status = 'untested',
    meta = jsonb_set(
      coalesce(meta, '{}'),
      '{qa_reconciled}',
      to_jsonb(format('SB-272: reconciled tested→untested (no test_cases found) on %s', now()::date::text))
    )
WHERE status = 'done'
  AND qa_status = 'tested'
  AND NOT EXISTS (SELECT 1 FROM public.test_cases tc WHERE tc.work_item_id = work_items.id);

-- Fix items marked 'untested' but that DO have linked test_cases
UPDATE public.work_items
SET qa_status = 'tested',
    meta = jsonb_set(
      coalesce(meta, '{}'),
      '{qa_reconciled}',
      to_jsonb(format('SB-272: reconciled untested→tested (test_cases exist) on %s', now()::date::text))
    )
WHERE status = 'done'
  AND qa_status = 'untested'
  AND EXISTS (SELECT 1 FROM public.test_cases tc WHERE tc.work_item_id = work_items.id);
;
