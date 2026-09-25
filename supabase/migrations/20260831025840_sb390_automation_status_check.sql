
-- SB-390 step 1: constrain the field that is about to become authoritative.
-- Verified beforehand that all 41 projects already hold 'active' or 'paused'.
alter table public.projects
  add constraint projects_automation_status_check
  check (automation_status in ('active','paused'));

comment on column public.projects.automation_status is
  'Authoritative automation flag (SB-390). The agent-runner gates on this. Replaces meta.dev_automation, which was retired in the same change.';
;
