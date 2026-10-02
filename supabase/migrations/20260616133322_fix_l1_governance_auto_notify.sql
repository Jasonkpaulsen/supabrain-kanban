
CREATE OR REPLACE FUNCTION enforce_authority_governance()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  lvl int;
  old_status text;
  status_changed boolean;
  jason_decided boolean;
BEGIN
  lvl := NEW.authority_level;
  IF lvl IS NULL THEN RETURN NEW; END IF;

  old_status := CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE OLD.status END;
  status_changed := NEW.status IS DISTINCT FROM old_status;
  jason_decided := COALESCE(NEW.approved_by, '') ILIKE 'jason%';

  -- L3+: approved_by must be Jason
  IF lvl >= 3 AND NEW.approved_by IS NOT NULL AND NOT jason_decided THEN
    RAISE EXCEPTION 'GOV-001: ticket % is L% — approved_by must be Jason, got "%"', NEW.ticket_code, lvl, NEW.approved_by;
  END IF;

  -- L4: only Jason may move out of awaiting_jason
  IF lvl = 4 AND status_changed AND old_status = 'awaiting_jason' AND NOT jason_decided THEN
    RAISE EXCEPTION 'GOV-001: ticket % is L4 executive — only Jason may move it out of awaiting_jason', NEW.ticket_code;
  END IF;

  -- Exiting awaiting_jason requires Jason decision
  IF old_status = 'awaiting_jason' AND NEW.status <> 'awaiting_jason'
     AND NOT (jason_decided AND NEW.approval_status IN ('approved','rejected')) THEN
    RAISE EXCEPTION 'GOV-001: ticket % may only exit awaiting_jason via Jason (approval_status approved/rejected + approved_by=Jason)', NEW.ticket_code;
  END IF;

  -- L3+: entering active states requires Jason approval
  IF lvl >= 3 AND status_changed AND NEW.status IN ('in_progress','review','done')
     AND NOT (NEW.approval_status = 'approved' AND jason_decided) THEN
    RAISE EXCEPTION 'GOV-001: ticket % is L% approval-required — cannot enter % without approval_status=approved by Jason', NEW.ticket_code, lvl, NEW.status;
  END IF;

  -- L2+: closing requires Jason decision
  IF lvl >= 2 AND status_changed AND NEW.status = 'done'
     AND NOT (NEW.approval_status = 'approved' OR (lvl = 2 AND NEW.approval_status = 'rejected')) THEN
    RAISE EXCEPTION 'GOV-001: ticket % is L% — cannot close without Jason decision (approval_status=%)', NEW.ticket_code, lvl, NEW.approval_status;
  END IF;

  -- L1: auto-set governance.notified when closing (notify-only — audit trigger still logs it)
  IF lvl = 1 AND status_changed AND NEW.status = 'done'
     AND COALESCE(NEW.meta->'governance'->>'notified','false') <> 'true' THEN
    NEW.meta := jsonb_set(coalesce(NEW.meta, '{}'), '{governance,notified}', '"true"');
  END IF;

  RETURN NEW;
END;
$$;
;
