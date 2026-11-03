-- SB-644 (re-verification of 20261026040133): audit attribution and two cancellation gaps.
--
-- 1. Entering awaiting_jason now clears approved_by (20261026040133), so the AFTER audit triggers,
--    which read NEW.approved_by, logged un-approves as 'unknown' and escalations as 'system'. Both
--    fall back to the approver before the write, which is what they recorded before SB-644.
-- 2. enforce_cancellation read the NEW level only, so lowering the level in the same write got
--    round its rules: an L3 ticket rejected by Jason reopened to backlog at L1, and an L3 wont_do
--    ticket reopened (or an L3 ticket was cancelled by an agent) at L1 with no Jason at all. It now
--    uses the higher of the old and new level for cancelling and reopening.
-- 3. A meta.reopened_by written while a ticket stays cancelled satisfied the Jason check on a later
--    reopen by anyone. It is dropped while the ticket stays cancelled, so only the reopening write
--    can name the reopener.

create or replace function public.audit_approval_reversal()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE
  v_actor   text;
  v_gesture text;
BEGIN
  IF NOT (OLD.approval_status IN ('approved','rejected')
          AND NEW.approval_status = 'pending') THEN
    RETURN NEW;
  END IF;

  -- If we reach AFTER, the BEFORE guard already allowed the reversal.
  -- SB-644: entering awaiting_jason clears approved_by, so fall back to the approver before the write.
  v_actor   := COALESCE(NEW.meta->>'reversal_actor', NEW.approved_by, OLD.approved_by, 'unknown');
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
$function$;

create or replace function public.audit_authority_governance()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE
  old_status text;
  jason_decided boolean;
  audit_decision text;
BEGIN
  -- SB-563: every cancellation and reopen is audited, whatever the authority level.
  IF TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status
     AND (NEW.status = 'cancelled' OR OLD.status = 'cancelled') THEN
    INSERT INTO governance_audit (user_id, work_item_id, from_status, to_status, authority_level, action_category, decided_by, decision, confidence, notes)
    VALUES (NEW.user_id, NEW.id, OLD.status, NEW.status, NEW.authority_level, NEW.action_category,
            CASE WHEN NEW.status = 'cancelled' THEN NEW.cancelled_by
                 ELSE COALESCE(NEW.meta->'cancel_history'->-1->>'reopened_by', NEW.assignee, 'system') END,
            CASE WHEN NEW.status = 'cancelled' THEN 'cancelled' ELSE 'reopened' END,
            NULL,
            CASE WHEN NEW.status = 'cancelled'
                 THEN format('trigger: audit_authority_governance; reason=%s; replaced_by=%s; note=%s',
                             NEW.cancel_reason, NEW.cancel_replaced_by, left(NEW.cancel_note, 300))
                 ELSE format('trigger: audit_authority_governance; reopened (was %s)', OLD.cancel_reason) END);
    RETURN NEW;
  END IF;

  IF NEW.authority_level IS NULL THEN RETURN NEW; END IF;
  old_status := CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE OLD.status END;
  IF NEW.status IS NOT DISTINCT FROM old_status THEN RETURN NEW; END IF;
  -- SB-644: entering awaiting_jason clears approved_by, so fall back to the approver before the write.
  jason_decided := COALESCE(NEW.approved_by, CASE WHEN TG_OP = 'UPDATE' THEN OLD.approved_by END, '') ILIKE 'jason%';
  audit_decision := CASE
    WHEN NEW.status = 'awaiting_jason' THEN 'escalated'
    WHEN old_status = 'awaiting_jason' AND NEW.approval_status = 'approved' THEN 'approved'
    WHEN old_status = 'awaiting_jason' AND NEW.approval_status = 'rejected' THEN 'rejected'
    WHEN NEW.authority_level = 1 AND NEW.status = 'done' THEN 'notified'
    ELSE 'auto' END;
  INSERT INTO governance_audit (user_id, work_item_id, from_status, to_status, authority_level, action_category, decided_by, decision, confidence, notes)
  VALUES (NEW.user_id, NEW.id, old_status, NEW.status, NEW.authority_level, NEW.action_category,
          CASE WHEN jason_decided THEN 'jason' ELSE COALESCE(NEW.assignee,'system') END,
          audit_decision,
          NULLIF(NEW.meta->'governance'->>'confidence','')::numeric,
          'trigger: audit_authority_governance');
  RETURN NEW;
END $function$;

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

  -- SB-644 (re-verification): judge by the higher of the old and new level, so lowering the level
  -- in the same write cannot get round the L2+/L3+ rules on cancelling or reopening
  v_lvl := coalesce(greatest(old.authority_level, new.authority_level), 1);

  -- staying cancelled: the decision is locked
  if old.status = 'cancelled' and new.status = 'cancelled' then
    -- reopened_by only counts in the write that reopens (SB-644): a value left here earlier is dropped
    new.meta := coalesce(new.meta, '{}'::jsonb) - 'reopened_by';
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
    if old.cancel_reason = 'rejected_by_jason' and greatest(old.authority_level, new.authority_level) <= 1 then
      if coalesce(new.meta->>'reopened_by', '') !~* '^jason' then
        raise exception 'CANCEL-005: % (L%) was rejected by Jason; only Jason can reopen it', old.ticket_code, v_lvl;
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
declare c text := pg_get_functiondef('public.enforce_cancellation()'::regprocedure);
begin
  if strpos(c, 'v_lvl := coalesce(greatest(old.authority_level, new.authority_level), 1);') = 0
     or strpos(c, 'greatest(old.authority_level, new.authority_level) <= 1') = 0
     or strpos(c, 'new.meta := coalesce(new.meta, ''{}''::jsonb) - ''reopened_by'';') = 0 then
    raise exception 'SB-644: enforce_cancellation is missing the level or reopened_by fix';
  end if;
  if strpos(pg_get_functiondef('public.audit_approval_reversal()'::regprocedure), 'OLD.approved_by') = 0
     or strpos(pg_get_functiondef('public.audit_authority_governance()'::regprocedure), 'OLD.approved_by') = 0 then
    raise exception 'SB-644: audit triggers do not fall back to the previous approver';
  end if;
  if not (select prosecdef from pg_proc where oid = 'public.audit_approval_reversal()'::regprocedure)
     or not (select prosecdef from pg_proc where oid = 'public.audit_authority_governance()'::regprocedure) then
    raise exception 'SB-644: audit triggers must stay SECURITY DEFINER';
  end if;
end
$assert$;