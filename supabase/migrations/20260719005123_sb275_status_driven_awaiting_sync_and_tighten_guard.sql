-- SB-275 (status-driven revision):
-- (1) On entering awaiting_jason from an approved/rejected card, flip approval_status
--     to 'pending' so the reversal trigger fires. Trigger name sorts before
--     enforce_approval_reversal and trg_approval_gate (BEFORE-UPDATE alphabetical),
--     so the flip is visible downstream.
-- (2) Tighten the reversal guard: reversal is now permitted ONLY in awaiting_jason.

CREATE OR REPLACE FUNCTION public.enforce_approval_awaiting_sync()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $fn$
BEGIN
  IF NEW.status = 'awaiting_jason'
     AND OLD.status IS DISTINCT FROM 'awaiting_jason'
     AND OLD.approval_status IN ('approved','rejected') THEN
    NEW.approval_status := 'pending';
  END IF;
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS enforce_approval_awaiting_sync ON public.work_items;
CREATE TRIGGER enforce_approval_awaiting_sync
  BEFORE UPDATE ON public.work_items
  FOR EACH ROW EXECUTE FUNCTION public.enforce_approval_awaiting_sync();

-- Tighten guard only; audit-append logic unchanged.
CREATE OR REPLACE FUNCTION public.enforce_approval_reversal()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $fn$
DECLARE
  v_actor   text;
  v_gesture text;
BEGIN
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
$fn$;;
