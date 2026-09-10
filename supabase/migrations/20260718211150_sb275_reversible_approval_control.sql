-- SB-275: Reversible approval control (backend enforcement + audit)
-- Detects approval reversal (approved/rejected -> pending), guards to pre-active
-- columns, appends an audit entry to meta.approval_history (BEFORE), and mirrors
-- a governance_audit row (AFTER). Minimal + additive. No client-callable RPC.

-- 1) Extend governance_audit.decision CHECK additively to allow reversal gestures.
--    (Superset of prior allowed values; existing rows unaffected.)
ALTER TABLE public.governance_audit DROP CONSTRAINT governance_audit_decision_check;
ALTER TABLE public.governance_audit ADD CONSTRAINT governance_audit_decision_check
  CHECK (decision = ANY (ARRAY[
    'approved','rejected','auto','deferred','escalated','notified',
    'un_approve','un_reject'
  ]));

-- 2) BEFORE UPDATE: guard + append to meta.approval_history
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

  -- GUARD: reversal only permitted in pre-active columns.
  IF NEW.status NOT IN ('backlog','todo','awaiting_jason') THEN
    RAISE EXCEPTION
      'Reversal blocked: ticket % cannot un-% while status = ''%'' — approval reversal is only allowed in pre-active columns (backlog, todo, awaiting_jason).',
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
$fn$;

-- 3) AFTER UPDATE: mirror to governance_audit. SECURITY DEFINER so the audit
--    insert succeeds under governance_audit RLS (matches audit_authority_governance).
--    This is a trigger function, NOT a client-callable RPC.
CREATE OR REPLACE FUNCTION public.audit_approval_reversal()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_actor   text;
  v_gesture text;
BEGIN
  IF NOT (OLD.approval_status IN ('approved','rejected')
          AND NEW.approval_status = 'pending') THEN
    RETURN NEW;
  END IF;

  -- If we reach AFTER, the BEFORE guard already allowed the reversal.
  v_actor   := COALESCE(NEW.meta->>'reversal_actor', NEW.approved_by, 'unknown');
  v_gesture := CASE OLD.approval_status WHEN 'approved' THEN 'un_approve' ELSE 'un_reject' END;

  INSERT INTO public.governance_audit (
    user_id, work_item_id, from_status, to_status,
    authority_level, action_category, decided_by, decision, confidence, notes
  ) VALUES (
    NEW.user_id, NEW.id, OLD.approval_status, 'pending',
    NEW.authority_level, NEW.action_category, v_actor, v_gesture, NULL,
    format('SB-275 approval reversal (%s) on ticket %s in column %s',
           v_gesture, COALESCE(NEW.ticket_code, NEW.id::text), NEW.status)
  );

  RETURN NEW;
END;
$fn$;

-- 4) Wire triggers. 'enforce_approval_reversal' sorts before the 'trg_*' BEFORE
--    triggers alphabetically, so the guard aborts early and the meta mutation is
--    visible to downstream triggers.
DROP TRIGGER IF EXISTS enforce_approval_reversal ON public.work_items;
CREATE TRIGGER enforce_approval_reversal
  BEFORE UPDATE ON public.work_items
  FOR EACH ROW EXECUTE FUNCTION public.enforce_approval_reversal();

DROP TRIGGER IF EXISTS audit_approval_reversal ON public.work_items;
CREATE TRIGGER audit_approval_reversal
  AFTER UPDATE ON public.work_items
  FOR EACH ROW EXECUTE FUNCTION public.audit_approval_reversal();
;
