-- SB-644 (verification of 20261026031138): keep Jason's own workflows working, close two gaps.
--
-- 1. Un-approving an L0/L1 ticket. enforce_approval_reversal allowed approved/rejected -> pending
--    only inside awaiting_jason, which L0/L1 can no longer enter, so Jason could not un-approve an
--    L0/L1 ticket at all (he did so on 3A-001 twice). L0/L1 never wait on Jason, so their reversal
--    now happens in place; the done-guard and the in-row audit are unchanged.
-- 2. Reopening an L0/L1 ticket cancelled as rejected_by_jason. CANCEL-005 forced such a reopen
--    into awaiting_jason, which SB-644 refuses, so it could never be reopened. Jason may now
--    reopen it to backlog or todo (meta.reopened_by, set by reopen_work_item). NULL-level and L2+
--    rejected tickets keep the old rule; L3+ still only reopen to awaiting_jason.
-- 3. An L0/L1 ticket could still end up in awaiting_jason by entering with a NULL level and being
--    classified in place. The entry rule now also refuses classifying or lowering to L0/L1 there
--    (a Jason-decided downgrade moves the ticket out in the same write).
-- 4. enforce_approval_awaiting_sync resets approval_status to pending on entry but kept
--    approved_by, so a stale "Jason" counted as the decision to leave, or to lower the level.
--    Entry now clears approved_by and approved_at.
-- The function body is otherwise as in 20261026031138, including the L2 close clause
-- (approval_status not_required or approved), which matched the live function before SB-644.

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
  -- SB-644 (verification): entering awaiting_jason clears the approver, so an old approval can
  -- never count as the decision that lets the ticket out again.
  IF status_changed AND NEW.status = 'awaiting_jason' THEN
    NEW.approved_by := NULL;
    NEW.approved_at := NULL;
  END IF;
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
  -- (also when a ticket already there is classified or lowered to L0/L1 in place)
  IF lvl <= 1 AND NEW.status = 'awaiting_jason' AND (status_changed OR lvl_was IS DISTINCT FROM lvl) THEN
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

create or replace function public.enforce_approval_reversal()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
DECLARE
  v_actor   text;
  v_gesture text;
BEGIN
  -- SB-276 RESIDUAL GUARD: block an approval DOWNGRADE while the card is done.
  -- Downgrade = approved/not_required -> pending/rejected. The only legitimate
  -- way to reverse an approval is to route the card through awaiting_jason
  -- (or, for L0/L1, in place: SB-644), never while 'done'.
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

  -- GUARD (tightened): reversal only permitted in the awaiting_jason column, except for L0/L1
  -- tickets, which never wait on Jason and are reversed in place (SB-644).
  IF NEW.status <> 'awaiting_jason' AND NOT coalesce(NEW.authority_level <= 1, false) THEN
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
$function$;

create or replace function public.enforce_cancellation()
returns trigger
language plpgsql
set search_path to ''
as $function$
declare
  v_actor  text;
  v_lvl    int := coalesce(new.authority_level, 1);
  v_jason  boolean;
  v_fields_set boolean := (new.cancel_reason is not null or new.cancel_note is not null
                           or new.cancel_replaced_by is not null or new.cancelled_at is not null
                           or new.cancelled_by is not null);
  v_hist   jsonb;
begin
  if tg_op = 'INSERT' then
    if new.status = 'cancelled' then
      raise exception 'CANCEL-007: % cannot be created as cancelled; create it, then cancel it', coalesce(new.ticket_code, 'a new ticket');
    end if;
    if v_fields_set then
      raise exception 'CANCEL-001: cancel_* fields are set only by cancelling a ticket';
    end if;
    return new;
  end if;

  -- staying cancelled: the decision is locked
  if old.status = 'cancelled' and new.status = 'cancelled' then
    if (new.cancel_reason, new.cancel_note, new.cancel_replaced_by, new.cancelled_at, new.cancelled_by)
       is distinct from
       (old.cancel_reason, old.cancel_note, old.cancel_replaced_by, old.cancelled_at, old.cancelled_by) then
      raise exception 'CANCEL-006: % is cancelled; its cancellation cannot be edited. Reopen it, then cancel it again', old.ticket_code;
    end if;
    return new;
  end if;

  -- leaving cancelled: reopen
  if old.status = 'cancelled' then
    if new.status not in ('backlog','todo','awaiting_jason') then
      raise exception 'CANCEL-005: % can only be reopened to backlog, todo or awaiting_jason (not %)', old.ticket_code, new.status;
    end if;
    -- SB-644: an L0/L1 ticket cannot wait on Jason, so one he rejected is reopened by Jason himself
    if old.cancel_reason = 'rejected_by_jason' and new.authority_level is not null and new.authority_level <= 1 then
      if coalesce(new.meta->>'reopened_by', '') !~* '^jason' then
        raise exception 'CANCEL-005: % (L%) was rejected by Jason; only Jason can reopen it', old.ticket_code, new.authority_level;
      end if;
    elsif (v_lvl >= 3 or old.cancel_reason = 'rejected_by_jason') and new.status <> 'awaiting_jason' then
      raise exception 'CANCEL-005: % (L%, %) can only be reopened to awaiting_jason, so Jason decides again',
        old.ticket_code, v_lvl, old.cancel_reason;
    end if;
    v_hist := jsonb_build_object(
      'reason', old.cancel_reason, 'note', old.cancel_note,
      'replaced_by', old.cancel_replaced_by, 'cancelled_at', old.cancelled_at,
      'cancelled_by', old.cancelled_by, 'reopened_at', now(),
      'reopened_by', coalesce(new.meta->>'reopened_by', new.assignee, 'system'),
      'reopened_to', new.status);
    new.meta := (coalesce(new.meta, '{}'::jsonb) - 'reopened_by')
                || jsonb_build_object('cancel_history',
                     coalesce(new.meta->'cancel_history', '[]'::jsonb) || jsonb_build_array(v_hist));
    new.cancel_reason := null; new.cancel_note := null; new.cancel_replaced_by := null;
    new.cancelled_at := null;  new.cancelled_by := null;
    return new;
  end if;

  -- not involved in a cancellation
  if new.status <> 'cancelled' then
    if v_fields_set then
      raise exception 'CANCEL-001: % is %, not cancelled; cancel_* fields are set only by cancelling it', new.ticket_code, new.status;
    end if;
    return new;
  end if;

  -- entering cancelled
  v_actor := btrim(coalesce(new.cancelled_by, ''));
  if new.cancel_reason is null then
    raise exception 'CANCEL-001: cancelling % needs cancel_reason (duplicate, superseded, no_longer_relevant, wont_do, rejected_by_jason)', new.ticket_code;
  end if;
  if v_actor = '' then
    raise exception 'CANCEL-001: cancelling % needs cancelled_by (who is cancelling it)', new.ticket_code;
  end if;
  if new.cancel_reason in ('duplicate','superseded') then
    if new.cancel_replaced_by is null or new.cancel_replaced_by = new.id then
      raise exception 'CANCEL-002: % cancelled as % must name the other ticket in cancel_replaced_by (not itself)',
        new.ticket_code, new.cancel_reason;
    end if;
  elsif length(btrim(coalesce(new.cancel_note, ''))) < 3 then
    raise exception 'CANCEL-002: % cancelled as % needs a one-line cancel_note', new.ticket_code, new.cancel_reason;
  end if;

  v_jason := v_actor ~* '^jason';
  if new.cancel_reason = 'rejected_by_jason' and not v_jason then
    raise exception 'CANCEL-003: only Jason can cancel % as rejected_by_jason (actor: %)', new.ticket_code, v_actor;
  end if;
  if (v_lvl >= 3 or old.status = 'awaiting_jason') and not v_jason then
    raise exception 'CANCEL-003: only Jason can cancel % (L%, status %; actor: %)',
      new.ticket_code, v_lvl, old.status, v_actor;
  end if;
  if v_lvl = 2 and not (v_jason or v_actor ~* '^jarvis' or v_actor ~ '(^|\s)PM($|\s)' or v_actor ~* 'project manager') then
    raise exception 'CANCEL-003: % is L2 — a PM, JARVIS or Jason must cancel it (actor: %)', new.ticket_code, v_actor;
  end if;

  if exists (select 1 from public.work_items c
              where c.parent_id = new.id and c.status not in ('done','cancelled') and not c.archived) then
    raise exception 'CANCEL-004: % still has open children; close or cancel them first', new.ticket_code;
  end if;

  new.cancelled_by := v_actor;
  -- The SB-563 backfill keeps each row's historical close time; everything else is stamped now.
  new.cancelled_at := case when current_setting('supabrain.cancel_backfill', true) = 'on' and new.cancelled_at is not null
                           then new.cancelled_at else now() end;
  -- GOV-001 lets a ticket leave awaiting_jason only on Jason's decision; a cancellation by
  -- Jason is that decision (trg_enforce_authority_governance runs after this trigger).
  if old.status = 'awaiting_jason' and v_jason then
    new.approval_status := 'rejected';
    new.approved_by := 'Jason';
    new.approved_at := now();
  end if;
  return new;
end;
$function$;


do $assert$
declare g text := pg_get_functiondef('public.enforce_authority_governance()'::regprocedure);
        v text := pg_get_functiondef('public.enforce_approval_reversal()'::regprocedure);
        c text := pg_get_functiondef('public.enforce_cancellation()'::regprocedure);
begin
  if strpos(g, 'NEW.approved_by := NULL;') = 0 or strpos(g, '(status_changed OR lvl_was IS DISTINCT FROM lvl)') = 0
     or strpos(g, 'COALESCE(GREATEST(lvl_was, lvl), -1) >= 2') = 0 then
    raise exception 'SB-644: governance trigger is missing the approver reset, the in-place rule or the exit rule';
  end if;
  if strpos(v, 'NOT coalesce(NEW.authority_level <= 1, false)') = 0 then
    raise exception 'SB-644: L0/L1 approval reversal in place is missing';
  end if;
  if strpos(c, 'only Jason can reopen it') = 0 then
    raise exception 'SB-644: L0/L1 rejected reopen rule is missing';
  end if;
  if exists (select 1 from public.work_items where status = 'awaiting_jason' and authority_level <= 1) then
    raise exception 'SB-644: an L0/L1 ticket is in awaiting_jason';
  end if;
end
$assert$;