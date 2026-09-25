CREATE OR REPLACE FUNCTION public.enforce_approval_gate()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  -- Fire only when transitioning INTO an active state
  IF NEW.status IN ('in_progress', 'review')
     AND (OLD.status IS NULL OR OLD.status NOT IN ('in_progress', 'review') OR OLD.status != NEW.status)
     -- 'not_required' means no approval is needed and is permitted; only un-granted approvals (e.g. 'pending') are blocked
     AND NEW.approval_status NOT IN ('approved', 'not_required')
  THEN
    RAISE EXCEPTION 'Approval required: ticket % cannot move to % without approval (current approval_status: %). Set approval_status=approved or route to awaiting_jason.',
      NEW.ticket_code, NEW.status, NEW.approval_status;
  END IF;
  RETURN NEW;
END;
$function$;;
