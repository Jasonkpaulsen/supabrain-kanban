
-- SB-402, and a correction to SB-393.
--
-- SB-393 said the chain block "cannot drift because it is generated". That was wrong in a
-- way the coverage gap obscured: agent_chain_of_command() was called ONCE during the
-- UPDATE and its output frozen into system_prompt. Change an agent's parent and the block
-- goes stale exactly like the prose it replaced. Generated-once is not generated.
--
-- This makes the claim true. Whenever an agent's reporting line changes, every prompt
-- carrying the marker is regenerated — the agent itself, and anyone whose directs list
-- just changed as a consequence.
create or replace function public.regenerate_chain_of_command_blocks()
returns trigger
language plpgsql
set search_path to 'public'
as $fn$
declare r record;
begin
  -- Rebuild for the moved agent, its old parent and its new parent: all three have a
  -- reporting line or a directs list that just changed.
  for r in
    select id from agents
     where system_prompt like '%## CHAIN OF COMMAND (generated%'
       and id in (new.id, old.reports_to_agent_id, new.reports_to_agent_id)
  loop
    update agents a
       set system_prompt = regexp_replace(
             a.system_prompt,
             '## CHAIN OF COMMAND \(generated[\s\S]*$',
             replace(public.agent_chain_of_command(a.id), '\', '\\')
           )
     where a.id = r.id;
  end loop;
  return null;
end;
$fn$;

-- AFTER, so agent_chain_of_command() reads committed values including the new FK.
drop trigger if exists trg_regen_chain_blocks on public.agents;
create trigger trg_regen_chain_blocks
  after update of reports_to_agent_id on public.agents
  for each row
  when (old.reports_to_agent_id is distinct from new.reports_to_agent_id)
  execute function public.regenerate_chain_of_command_blocks();

comment on function public.regenerate_chain_of_command_blocks() is
  'SB-402: rebuilds the generated chain-of-command block in system_prompt whenever a reporting line changes. Without this the block is generated once and then stale — which is what SB-393 shipped.';
;
