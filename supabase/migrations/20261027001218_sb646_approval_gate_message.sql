-- SB-646: the approval gate's refusal no longer sends L0/L1 work to awaiting_jason (SB-644 refuses
-- that) and no longer suggests self-approval. Behaviour is unchanged; only the message text differs.
CREATE OR REPLACE FUNCTION public.enforce_approval_gate()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  -- Fire only when transitioning INTO an active state
  IF NEW.status IN ('in_progress', 'review')
     AND (OLD.status IS NULL OR OLD.status NOT IN ('in_progress', 'review') OR OLD.status != NEW.status)
     -- 'not_required' means no approval is needed and is permitted; only un-granted approvals (e.g. 'pending') are blocked
     AND NEW.approval_status NOT IN ('approved', 'not_required')
  THEN
    RAISE EXCEPTION 'Approval required: ticket % cannot move to % without approval (current approval_status: %). Do not retry: an L2+ ticket that needs Jason goes to awaiting_jason with a decision package; an L0/L1 ticket stays where it is with a comment for its PM (L0/L1 tickets cannot wait on Jason: SB-644).',
      NEW.ticket_code, NEW.status, NEW.approval_status;
  END IF;
  RETURN NEW;
END;
$function$;