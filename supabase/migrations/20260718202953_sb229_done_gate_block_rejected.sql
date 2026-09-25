CREATE OR REPLACE FUNCTION public.enforce_done_gate()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  exempt_types text[] := ARRAY['epic', 'chore', 'spike', 'requirement'];
  grandfather_date timestamptz := '2026-06-17T00:00:00Z';
BEGIN
  -- Only fire on transition INTO done
  IF NEW.status != 'done' OR (OLD.status IS NOT NULL AND OLD.status = 'done') THEN
    RETURN NEW;
  END IF;

  -- =========================================================================
  -- GATE 1: APPROVAL GATE  (SB-229 Wave 2: now blocks 'rejected' as well as 'pending')
  -- Block tickets with approval_status IN ('pending','rejected') from reaching done.
  -- Allows: 'approved', 'not_required'
  -- Exemptions: grandfathered (created before 2026-06-17), meta.approval_gate_exempt
  -- =========================================================================
  IF NEW.approval_status IN ('pending', 'rejected')
     AND NEW.created_at >= grandfather_date
     AND NOT COALESCE((NEW.meta->>'approval_gate_exempt')::boolean, false)
  THEN
    RAISE EXCEPTION
      'Approval required: ticket % cannot move to done with approval_status = ''%'' (must be ''approved'' or ''not_required''). '
      'Get approval first, or set meta.approval_gate_exempt = true to bypass this gate.',
      NEW.ticket_code, NEW.approval_status;
  END IF;

  -- =========================================================================
  -- GATE 2: REVIEW-REQUIRED GATE
  -- Non-exempt tickets created on or after 2026-06-17 must have passed
  -- through review (review_entered_at IS NOT NULL) before reaching done.
  -- Exempt types: epic, chore, spike, requirement
  -- Override: meta.review_gate_exempt = true
  -- =========================================================================
  IF NOT (NEW.type = ANY(exempt_types))
     AND NEW.created_at >= grandfather_date
     AND NOT COALESCE((NEW.meta->>'review_gate_exempt')::boolean, false)
  THEN
    IF NEW.review_entered_at IS NULL AND (OLD.status IS NULL OR OLD.status != 'review') THEN
      RAISE EXCEPTION
        'Review required: ticket % (type: %) cannot move to done without passing through review. '
        'review_entered_at is null — this ticket has not been reviewed. '
        'Move to review status first, or set meta.review_gate_exempt = true to bypass this gate.',
        NEW.ticket_code, NEW.type;
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;;
