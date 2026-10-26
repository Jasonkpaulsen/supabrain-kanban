-- SB-644 (ADR-GOV-001-A2): L0/L1 tickets never wait on Jason.
--
-- authority_levels: L0 autonomous and L1 notify never wait on Jason; L2 recommend waits in
-- awaiting_jason until he decides. enforce_authority_governance() let any writer move a ticket of
-- any level INTO awaiting_jason, but let it OUT only on a Jason decision. So when a sweep parked an
-- L1 ticket there (SB-599, 2026-10-20), nothing but Jason could release it. Jason approved the
-- change on 2026-10-26; it is narrowed from the proposal's L0-L2 to L0-L1 because L2 waiting on
-- Jason is the design (18 L2 entries on record).
--
-- 1. Entry: an L0 or L1 ticket cannot enter awaiting_jason. A low-level item that really needs
--    Jason is raised to L2 with a decision package (allowed in the same write).
-- 2. Exit: a ticket that is L0/L1 both before and after the write may leave without a Jason
--    decision. The check now uses the higher of the old and new level and runs before the NULL
--    early return, so clearing the level no longer frees an L2+ ticket.
-- 3. While in awaiting_jason, authority_level cannot be lowered or cleared without a Jason
--    decision, so the exit rule cannot be dodged by a downgrade.
-- NULL-level tickets (e.g. the CRM steward digest) and the L3/L4 rules are unchanged.

create or replace function public.enforce_authority_governance()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
DECLARE
  lvl int;
  lvl_was int;
  old_status text;
  status_changed boolean;
  jason_decided boolean;
BEGIN
  lvl := NEW.authority_level;
  lvl_was := CASE WHEN TG_OP = 'UPDATE' THEN OLD.authority_level END;
  old_status := CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE OLD.status END;
  status_changed := NEW.status IS DISTINCT FROM old_status;
  jason_decided := COALESCE(NEW.approved_by, '') ILIKE 'jason%';

  -- SB-644: in awaiting_jason, the level cannot be lowered or cleared without a Jason decision
  IF old_status = 'awaiting_jason' AND lvl_was IS NOT NULL
     AND (lvl IS NULL OR lvl < lvl_was)
     AND NOT (jason_decided AND NEW.approval_status IN ('approved','rejected')) THEN
    RAISE EXCEPTION 'GOV-001 (SB-644): ticket % is in awaiting_jason; its authority level (L%) can only be lowered by Jason', NEW.ticket_code, lvl_was;
  END IF;

  -- Exiting awaiting_jason requires a Jason decision, unless the ticket is L0/L1 before and after (SB-644)
  IF old_status = 'awaiting_jason' AND NEW.status IS DISTINCT FROM 'awaiting_jason'
     AND COALESCE(GREATEST(lvl_was, lvl), -1) >= 2
     AND NOT (jason_decided AND NEW.approval_status IN ('approved','rejected')) THEN
    RAISE EXCEPTION 'GOV-001: ticket % may only exit awaiting_jason via Jason (approval_status approved/rejected + approved_by=Jason)', NEW.ticket_code;
  END IF;

  IF lvl IS NULL THEN RETURN NEW; END IF;

  -- SB-644: L0/L1 work never waits on Jason
  IF lvl <= 1 AND status_changed AND NEW.status = 'awaiting_jason' THEN
    RAISE EXCEPTION 'GOV-001 (SB-644): ticket % is L% — L0/L1 work never waits on Jason. Hand it to its owning PM, or raise authority_level to 2 with a decision package.', NEW.ticket_code, lvl;
  END IF;

  -- L3+: approved_by must be Jason
  IF lvl >= 3 AND NEW.approved_by IS NOT NULL AND NOT jason_decided THEN
    RAISE EXCEPTION 'GOV-001: ticket % is L% — approved_by must be Jason, got "%"', NEW.ticket_code, lvl, NEW.approved_by;
  END IF;

  -- L4: only Jason may move out of awaiting_jason
  IF lvl = 4 AND status_changed AND old_status = 'awaiting_jason' AND NOT jason_decided THEN
    RAISE EXCEPTION 'GOV-001: ticket % is L4 executive — only Jason may move it out of awaiting_jason', NEW.ticket_code;
  END IF;

  -- L3+: entering active states requires Jason approval
  IF lvl >= 3 AND status_changed AND NEW.status IN ('in_progress','review','done')
     AND NOT (NEW.approval_status = 'approved' AND jason_decided) THEN
    RAISE EXCEPTION 'GOV-001: ticket % is L% approval-required — cannot enter % without approval_status=approved by Jason', NEW.ticket_code, lvl, NEW.status;
  END IF;

  -- L2+: closing requires Jason decision
  IF lvl >= 2 AND status_changed AND NEW.status = 'done'
     AND NOT (NEW.approval_status IN ('approved', 'not_required') OR (lvl = 2 AND NEW.approval_status = 'rejected')) THEN
    RAISE EXCEPTION 'GOV-001: ticket % is L% — cannot close without Jason decision (approval_status=%)', NEW.ticket_code, lvl, NEW.approval_status;
  END IF;

  -- L1: auto-set governance.notified when closing (notify-only — audit trigger still logs it)
  IF lvl = 1 AND status_changed AND NEW.status = 'done'
     AND COALESCE(NEW.meta->'governance'->>'notified','false') <> 'true' THEN
    NEW.meta := jsonb_set(coalesce(NEW.meta, '{}'), '{governance,notified}', '"true"');
  END IF;

  RETURN NEW;
END;
$function$;

do $assert$
declare d text := pg_get_functiondef('public.enforce_authority_governance()'::regprocedure);
begin
  if strpos(d, 'lvl <= 1 AND status_changed AND NEW.status = ''awaiting_jason''') = 0
     or strpos(d, 'COALESCE(GREATEST(lvl_was, lvl), -1) >= 2') = 0
     or strpos(d, 'can only be lowered by Jason') = 0 then
    raise exception 'SB-644: enforce_authority_governance is missing the entry, exit or downgrade rule';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'trg_enforce_authority_governance'
                   and tgrelid = 'public.work_items'::regclass and tgenabled = 'O') then
    raise exception 'SB-644: trg_enforce_authority_governance missing or disabled';
  end if;
  if exists (select 1 from public.work_items where status = 'awaiting_jason' and authority_level <= 1) then
    raise exception 'SB-644: an L0/L1 ticket is in awaiting_jason; release it first';
  end if;
end
$assert$;