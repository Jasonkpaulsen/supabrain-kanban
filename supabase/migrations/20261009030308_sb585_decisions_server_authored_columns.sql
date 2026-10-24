-- SB-585 QA defect D1 (TC-SB585-5): GENERATED ALWAYS does not stop INSERT ... OVERRIDING SYSTEM VALUE,
-- and that needs no privilege beyond INSERT. A signed-in owner could write a resume row with a huge
-- seq and, the log being append-only, defeat auto-merge suspension forever (or forge an equal-seq tie).
-- Fix: authenticated gets INSERT only on the columns a caller legitimately supplies. seq, id and
-- created_at are server-authored (id and created_at are audit fields SB-574's weekly window relies on);
-- supplying any of them is now refused with 42501. seq is also unique, so a tie cannot be forged even
-- by a privileged role.

revoke insert on public.crm_steward_decisions from authenticated;
grant insert (user_id, actor_id, decision, rule, entity_type, entity_id, reason_code,
              merge_log_id, run_id, refers_to, qa_verdict)
  on public.crm_steward_decisions to authenticated;

create unique index crm_steward_decisions_seq_unique on public.crm_steward_decisions (seq);

do $chk$
begin
  if has_table_privilege('authenticated', 'public.crm_steward_decisions', 'insert') then
    raise exception 'A1: authenticated must not hold table-level INSERT on crm_steward_decisions';
  end if;
  if has_column_privilege('authenticated', 'public.crm_steward_decisions', 'seq', 'insert')
     or has_column_privilege('authenticated', 'public.crm_steward_decisions', 'id', 'insert')
     or has_column_privilege('authenticated', 'public.crm_steward_decisions', 'created_at', 'insert') then
    raise exception 'A2: seq, id and created_at must not be insertable by authenticated';
  end if;
  if not has_column_privilege('authenticated', 'public.crm_steward_decisions', 'decision', 'insert')
     or not has_column_privilege('authenticated', 'public.crm_steward_decisions', 'run_id', 'insert') then
    raise exception 'A3: authenticated must still insert ordinary decision columns';
  end if;
  if has_table_privilege('authenticated', 'public.crm_steward_decisions', 'update')
     or has_table_privilege('authenticated', 'public.crm_steward_decisions', 'delete') then
    raise exception 'A4: the decision log stays append-only for authenticated';
  end if;
end $chk$;
