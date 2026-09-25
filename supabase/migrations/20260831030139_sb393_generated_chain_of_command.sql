
-- SB-393: the chain of command is generated from the org chart, never typed.
--
-- Reporting lines were previously restated in prose inside system_prompt, which is a
-- third copy of a fact the FK already holds. SB-387 existed for no other reason than
-- to re-align those copies. This function composes the block at read time so the
-- copy cannot drift: change an agent's parent and its prompt block changes with it.
create or replace function public.agent_chain_of_command(p_agent_id uuid)
returns text
language sql
stable
set search_path to 'public'
as $fn$
  select
    '## CHAIN OF COMMAND (generated — do not edit by hand)' || chr(10) ||
    'You report to ' ||
      coalesce((select r.name from agents r where r.id = a.reports_to_agent_id),
               a.reports_to_human, '(unset)') || '.' || chr(10) ||
    coalesce(
      (select 'Your direct reports are:' || chr(10) ||
              string_agg('- ' || d.direct_name, chr(10) order by d.direct_name)
         from agent_directs d where d.agent_id = a.id),
      'You have no direct reports.') || chr(10) ||
    'Escalation path: ' ||
      array_to_string((select e.escalation_chain from agent_escalation_path e where e.agent_id = a.id), ' → ') ||
      case when (select e.stops_at_ceiling from agent_escalation_path e where e.agent_id = a.id)
           then '. Escalation stops there — that owner decides what, if anything, goes further.'
           else '.' end || chr(10) ||
    'Escalate rather than guessing when an action exceeds your delegated authority, ' ||
    'when a deadline is at risk, or when information is missing that prevents safe ' ||
    'completion. Never halt silently.'
  from agents a where a.id = p_agent_id;
$fn$;

-- SB-393: an active agent with no authored prompt is a row that looks staffed and is
-- not. The runner (v9) already refuses to dispatch one; this stops the state existing.
create or replace function public.enforce_agent_prompt_present()
returns trigger
language plpgsql
set search_path to 'public'
as $fn$
begin
  if new.status = 'active'
     and coalesce(trim(new.system_prompt), '') = ''
     and not coalesce((new.meta->>'qa_fixture')::boolean, false)
  then
    raise exception 'SB-393: agent "%" cannot be active with an empty system_prompt. Author one, set meta.qa_fixture for test scaffolding, or use a non-active status.', new.name
      using errcode = 'check_violation';
  end if;
  return new;
end;
$fn$;
;
