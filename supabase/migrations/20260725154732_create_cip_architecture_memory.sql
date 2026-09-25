create table if not exists public.cip_architecture_memory (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null default '90811455-9c92-4f72-b52b-42bdff719937',
  user_id uuid not null default '5ecbd44a-a3e2-4363-9133-dff3851ba0f5',
  category text not null,
  slug text not null,
  title text not null,
  body text not null,
  refs jsonb not null default '{}'::jsonb,
  source text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists cip_architecture_memory_project_slug_uidx
  on public.cip_architecture_memory (project_id, slug);

alter table public.cip_architecture_memory enable row level security;

drop policy if exists cip_architecture_memory_owner_all on public.cip_architecture_memory;
create policy cip_architecture_memory_owner_all
  on public.cip_architecture_memory
  for all
  to authenticated
  using (user_id = '5ecbd44a-a3e2-4363-9133-dff3851ba0f5')
  with check (user_id = '5ecbd44a-a3e2-4363-9133-dff3851ba0f5');

comment on table public.cip_architecture_memory is 'Durable, queryable architecture memory for CIP (Campaign Intelligence Platform) — distilled ADRs, epic designs, decisions, build-state, conventions and ops notes, mirrored from Jason''s local file-based auto-memory. UPSERT key = (project_id, slug).';;
