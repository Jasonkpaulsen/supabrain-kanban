-- SB-276: Gate-enforcement completeness fix
-- 1) INSERT BYPASS: rebind done gate (and qa gate) to also fire on INSERT.
--    Function bodies are UNCHANGED (they already null-guard OLD correctly).
-- 2) RESIDUAL: extend enforce_approval_reversal to block an approval DOWNGRADE
--    (approved/not_required -> pending/rejected) while status='done', unless
--    routed through awaiting_jason (that path never has NEW.status='done').

-- (1a) Done gate: BEFORE INSERT OR UPDATE
DROP TRIGGER IF EXISTS trg_done_gate ON public.work_items;
CREATE TRIGGER trg_done_gate
  BEFORE INSERT OR UPDATE ON public.work_items
  FOR EACH ROW EXECUTE FUNCTION enforce_done_gate();

-- (1b) QA gate: BEFORE INSERT OR UPDATE (sets qa_status on done-INSERT; no-op otherwise)
DROP TRIGGER IF EXISTS trg_qa_gate ON public.work_items;
CREATE TRIGGER trg_qa_gate
  BEFORE INSERT OR UPDATE ON public.work_items
  FOR EACH ROW EXECUTE FUNCTION enforce_qa_gate();

-- (2) Residual downgrade guard added atop the existing reversal logic.
CREATE OR REPLACE FUNCTION public.enforce_approval_reversal()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_actor   text;
  v_gesture text;
BEGIN
  -- SB-276 RESIDUAL GUARD: block an approval DOWNGRADE while the card is done.
  -- Downgrade = approved/not_required -> pending/rejected. The only legitimate
  -- way to reverse an approval is to route the card through awaiting_jason,
  -- where NEW.status='awaiting_jason' (never 'done'), so this guard is inert
  -- for the SB-275 reversal path and the awaiting-sync trigger.
  IF NEW.status = 'done'
     AND OLD.approval_status IN ('approved','not_required')
     AND NEW.approval_status IN ('pending','rejected')
     AND NEW.approval_status IS DISTINCT FROM OLD.approval_status
  THEN
    RAISE EXCEPTION
      'Approval downgrade blocked: ticket % cannot change approval_status from ''%'' to ''%'' while status = ''done''. Route through the awaiting_jason column to reverse an approval.',
      NEW.ticket_code, OLD.approval_status, NEW.approval_status;
  END IF;

  -- Reversal is strictly: approved/rejected -> pending. Everything else untouched.
  IF NOT (OLD.approval_status IN ('approved','rejected')
          AND NEW.approval_status = 'pending') THEN
    RETURN NEW;
  END IF;

  -- GUARD (tightened): reversal only permitted in the awaiting_jason column.
  IF NEW.status <> 'awaiting_jason' THEN
    RAISE EXCEPTION
      'Reversal blocked: ticket % cannot un-% while status = ''%'' — approval reversal is only allowed in the awaiting_jason column.',
      NEW.ticket_code,
      CASE OLD.approval_status WHEN 'approved' THEN 'approve' ELSE 'reject' END,
      NEW.status;
  END IF;

  v_actor   := COALESCE(NEW.meta->>'reversal_actor', NEW.approved_by, 'unknown');
  v_gesture := CASE OLD.approval_status WHEN 'approved' THEN 'un_approve' ELSE 'un_reject' END;

  -- AUDIT (in-row): append one object to meta.approval_history.
  NEW.meta := jsonb_set(
    COALESCE(NEW.meta, '{}'::jsonb),
    '{approval_history}',
    COALESCE(NEW.meta->'approval_history', '[]'::jsonb)
      || jsonb_build_object(
           'actor',   v_actor,
           'from',    OLD.approval_status,
           'to',      'pending',
           'at',      now(),
           'gesture', v_gesture
         )
  );

  RETURN NEW;
END;
$function$;;
