
-- SB-391 step 1: the org chart becomes a foreign key.
--
-- meta.reports_to was a name string validated by nothing. Two spellings of one
-- parent lived in it ("JARVIS" x10, "JARVIS — Master Orchestrator" x16) and a
-- person's name ("Jason") sat in the same field as agent references, so no check
-- could tell a legitimate root from a typo. reports_to_human separates those.
alter table public.agents
  add column if not exists reports_to_agent_id uuid references public.agents(id) on delete set null,
  add column if not exists reports_to_human text;

comment on column public.agents.reports_to_agent_id is
  'Parent agent. Authoritative org chart edge (SB-391). Replaces meta.reports_to.';
comment on column public.agents.reports_to_human is
  'Set only where an agent reports to a person rather than an agent (the apex root). Mutually exclusive with reports_to_agent_id.';

create index if not exists agents_reports_to_agent_id_idx on public.agents(reports_to_agent_id);
;
