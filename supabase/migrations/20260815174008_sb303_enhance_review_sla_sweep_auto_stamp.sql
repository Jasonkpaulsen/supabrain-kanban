
-- SB-303: Enhance review_sla_sweep to auto-stamp review_sla_breached_at at 72h
CREATE OR REPLACE FUNCTION review_sla_sweep()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_breaches jsonb;
  v_over jsonb;
  v_stamped integer;
  v_summary text;
BEGIN
  -- Auto-stamp review_sla_breached_at on items that hit 72h hard breach
  UPDATE work_items
  SET review_sla_breached_at = now(),
      updated_at = now()
  WHERE status = 'review'
    AND review_entered_at IS NOT NULL
    AND review_sla_breached_at IS NULL
    AND EXTRACT(epoch FROM (now() - review_entered_at)) / 3600.0 >= 72;
  GET DIAGNOSTICS v_stamped = ROW_COUNT;

  -- Collect current breaches (48h+)
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'ticket', ticket_code,
    'reviewer', assignee,
    'hours', hours_in_review,
    'level', breach_level
  ) ORDER BY hours_in_review DESC), '[]'::jsonb)
  INTO v_breaches
  FROM v_review_sla_breaches;

  -- Collect WIP-overloaded flags
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'ticket', ticket_code,
    'note', meta->>'reviewer_over_wip'
  )), '[]'::jsonb)
  INTO v_over
  FROM work_items
  WHERE status = 'review' AND NOT archived AND meta ? 'reviewer_over_wip';

  v_summary := CASE
    WHEN jsonb_array_length(v_breaches) = 0 AND jsonb_array_length(v_over) = 0
      THEN 'Review SLA: all clear — no breach over 48h, no overloaded reviewer.'
    ELSE format('Review SLA: %s breach(es) (48h+), %s newly stamped at 72h, %s overloaded-reviewer flag(s).',
                jsonb_array_length(v_breaches), v_stamped, jsonb_array_length(v_over))
  END;

  INSERT INTO activity_log (project_id, user_id, agent_name, action, target_table, summary, meta)
  VALUES (
    'a07a7f3d-722f-468f-81fa-84e2c5fba704',
    '5ecbd44a-a3e2-4363-9133-dff3851ba0f5',
    'System',
    'commented',
    'work_items',
    v_summary,
    jsonb_build_object(
      'artifact', 'review_sla',
      'breaches', v_breaches,
      'overloaded', v_over,
      'auto_stamped_count', v_stamped
    )
  );

  RETURN jsonb_build_object(
    'summary', v_summary,
    'breaches', v_breaches,
    'overloaded', v_over,
    'auto_stamped_count', v_stamped
  );
END;
$$;
;
