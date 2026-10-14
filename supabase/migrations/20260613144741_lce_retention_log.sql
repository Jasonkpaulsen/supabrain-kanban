
create table if not exists public.lce_deletion_log (
  id uuid primary key default gen_random_uuid(),
  user_id uuid,
  entity_type text not null,        -- 'article' | 'image' | 'image_request'
  entity_id uuid,
  title text,
  storage_path text,
  reason text,                      -- 'auto_purge' | 'manual_empty_trash' | 'manual_delete'
  grace_days integer,
  purged_at timestamptz not null default now(),
  meta jsonb not null default '{}'::jsonb
);
create index if not exists idx_deletionlog_purged on public.lce_deletion_log(purged_at desc);
alter table public.lce_deletion_log enable row level security;
create policy "service_role_full" on public.lce_deletion_log for all to service_role using (true) with check (true);
create policy "users_select_own" on public.lce_deletion_log for select to authenticated using (user_id is null or (select auth.uid())=user_id);
comment on table public.lce_deletion_log is 'Audit trail of permanently purged LCE records (articles/images). Written by the lce-cleanup retention job and manual purges. ADR-LCE-003.';
;
