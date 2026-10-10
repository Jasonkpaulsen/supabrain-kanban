
drop trigger if exists trg_agent_prompt_present on public.agents;
create trigger trg_agent_prompt_present
  before insert or update on public.agents
  for each row execute function public.enforce_agent_prompt_present();
;
