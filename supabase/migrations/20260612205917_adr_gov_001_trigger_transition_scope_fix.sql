-- Scope GUARD 4/5 to status transitions so backfill-classification of legacy rows doesn't violate state invariants
CREATE OR REPLACE FUNCTION enforce_authority_governance() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  lvl int;
  old_status text;
  status_changed boolean;
  jason_decided boolean;
  audit_decision text;
BEGIN
  lvl := NEW.authority_level;
  IF lvl IS NULL THEN RETURN NEW; END IF;

  old_status := CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE OLD.status END;
  status_changed := NEW.status IS DISTINCT FROM old_status;
  jason_decided := COALESCE(NEW.approved_by, '') ILIKE 'jason%';

  IF lvl >= 3 AND NEW.approved_by IS NOT NULL AND NOT jason_decided THEN
    RAISE EXCEPTION 'GOV-001: ticket % is L% — approved_by must be Jason, got "%"', NEW.ticket_code, lvl, NEW.approved_by;
  END IF;

  IF lvl = 4 AND status_changed AND old_status = 'awaiting_jason' AND NOT jason_decided THEN
    RAISE EXCEPTION 'GOV-001: ticket % is L4 executive — only Jason may move it out of awaiting_jason', NEW.ticket_code;
  END IF;

  IF old_status = 'awaiting_jason' AND NEW.status <> 'awaiting_jason'
     AND NOT (jason_decided AND NEW.approval_status IN ('approved','rejected')) THEN
    RAISE EXCEPTION 'GOV-001: ticket % may only exit awaiting_jason via Jason (approval_status approved/rejected + approved_by=Jason)', NEW.ticket_code;
  END IF;

  IF lvl >= 3 AND status_changed AND NEW.status IN ('in_progress','review','done')
     AND NOT (NEW.approval_status = 'approved' AND jason_decided) THEN
    RAISE EXCEPTION 'GOV-001: ticket % is L% approval-required — cannot enter % without approval_status=approved by Jason', NEW.ticket_code, lvl, NEW.status;
  END IF;

  IF lvl >= 2 AND status_changed AND NEW.status = 'done'
     AND NOT (NEW.approval_status = 'approved' OR (lvl = 2 AND NEW.approval_status = 'rejected')) THEN
    RAISE EXCEPTION 'GOV-001: ticket % is L% — cannot close without Jason decision (approval_status=%)', NEW.ticket_code, lvl, NEW.approval_status;
  END IF;

  IF lvl = 1 AND status_changed AND NEW.status = 'done'
     AND COALESCE(NEW.meta->'governance'->>'notified','false') <> 'true' THEN
    RAISE EXCEPTION 'GOV-001: ticket % is L1 notify-only — set meta.governance.notified=true before closing', NEW.ticket_code;
  END IF;

  IF status_changed THEN
    audit_decision := CASE
      WHEN NEW.status = 'awaiting_jason' THEN 'escalated'
      WHEN old_status = 'awaiting_jason' AND NEW.approval_status = 'approved' THEN 'approved'
      WHEN old_status = 'awaiting_jason' AND NEW.approval_status = 'rejected' THEN 'rejected'
      WHEN lvl = 1 AND NEW.status = 'done' THEN 'notified'
      ELSE 'auto' END;
    INSERT INTO governance_audit (user_id, work_item_id, from_status, to_status, authority_level, action_category, decided_by, decision, confidence, notes)
    VALUES (NEW.user_id, NEW.id, old_status, NEW.status, lvl, NEW.action_category,
            CASE WHEN jason_decided THEN 'jason' ELSE COALESCE(NEW.assignee,'system') END,
            audit_decision,
            NULLIF(NEW.meta->'governance'->>'confidence','')::numeric,
            'trigger: enforce_authority_governance');
  END IF;

  RETURN NEW;
END $$;;
