alter table public.agents add column if not exists alias text;

alter table public.agents drop constraint if exists agents_alias_format;
alter table public.agents add constraint agents_alias_format
  check (alias is null or char_length(btrim(alias)) between 1 and 50);

create unique index if not exists agents_user_alias_ci_uidx
  on public.agents (user_id, lower(alias)) where alias is not null;

comment on column public.agents.alias is
  'Optional human-friendly name used as an alternate activation key (e.g., "Liz"). Unique per user, case-insensitive.';;
