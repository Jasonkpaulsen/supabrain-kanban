-- SB-650: one-time upload tickets for lce-image-ingest (option (b), approved by Jason 2026-10-28).
--
-- The "Lce image request fulfiller" routine held the SB-497 static token in plaintext in its prompt.
-- Instead, the routine now asks the database for tickets through the Supabase access it already has:
-- lce_issue_upload_tickets(request_id, count) returns, per image, a fresh object path and a ticket
-- that works once, for that path only, within 30 minutes. Only sha256(ticket) is stored.
-- lce-image-ingest v4 checks a ticket without using it (lce_upload_ticket_valid), validates the path,
-- then uses it atomically for that exact path (lce_consume_upload_ticket).
--
-- The static token is retired outright: v4 no longer reads x-token, and the Vault secret behind
-- lce_image_ingest_token_matches() is overwritten with fresh random bytes generated here, so no
-- earlier copy of it authenticates anywhere. The matcher is left in place (no drops) with no caller.
--
-- Grants are revoked BY ROLE NAME (SB-408/440/447/493/497): REVOKE ... FROM PUBLIC does not undo
-- per-role default grants. The service role (which the edge function uses) can check and use
-- tickets but cannot issue them.

create table public.lce_upload_tickets (
  id          uuid primary key default gen_random_uuid(),
  token_hash  bytea not null unique,
  object_path text  not null unique,
  request_id  uuid references public.image_requests(id) on delete set null,
  set_id      uuid,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  used_at     timestamptz,
  meta        jsonb not null default '{}'::jsonb
);
comment on table public.lce_upload_tickets is
  'SB-650: one-time, path-bound upload tickets for lce-image-ingest. Stores sha256 of each ticket only. No client access.';
alter table public.lce_upload_tickets enable row level security;
revoke all on table public.lce_upload_tickets from public, anon, authenticated;

create or replace function public.lce_issue_upload_tickets(p_request_id uuid, p_count int default 3)
returns table (set_id uuid, sort_order int, object_path text, ticket text)
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare
  v_set  uuid := gen_random_uuid();
  v_tick text;
  v_path text;
  i      int;
begin
  if p_count is null or p_count < 1 or p_count > 5 then
    raise exception 'SB-650: count must be between 1 and 5 (got %)', p_count;
  end if;
  if not exists (select 1 from public.image_requests r where r.id = p_request_id and r.status = 'processing') then
    raise exception 'SB-650: image request % is not processing; mark it processing first', p_request_id;
  end if;
  if (select count(*) from public.lce_upload_tickets t where t.request_id = p_request_id) + p_count > 15 then
    raise exception 'SB-650: image request % already has the maximum of 15 upload tickets', p_request_id;
  end if;
  for i in 1 .. p_count loop
    v_tick := 'lce-upl-' || encode(extensions.gen_random_bytes(24), 'hex');
    v_path := format('lce-images/%s/candidate-%s.png', v_set, i);
    insert into public.lce_upload_tickets (token_hash, object_path, request_id, set_id, expires_at)
    values (sha256(convert_to(v_tick, 'UTF8')), v_path, p_request_id, v_set, now() + interval '30 minutes');
    set_id := v_set; sort_order := i; object_path := v_path; ticket := v_tick;
    return next;
  end loop;
end
$function$;

create or replace function public.lce_upload_ticket_valid(p_ticket text)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select exists (select 1 from public.lce_upload_tickets t
                  where t.token_hash = sha256(convert_to(p_ticket, 'UTF8'))
                    and t.used_at is null
                    and t.expires_at > now())
$function$;

create or replace function public.lce_consume_upload_ticket(p_ticket text, p_path text)
returns boolean
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare v_id uuid;
begin
  update public.lce_upload_tickets t
     set used_at = now()
   where t.token_hash = sha256(convert_to(p_ticket, 'UTF8'))
     and t.object_path = p_path
     and t.used_at is null
     and t.expires_at > now()
  returning t.id into v_id;
  return v_id is not null;
end
$function$;

revoke all on function public.lce_issue_upload_tickets(uuid, int) from public, anon, authenticated, service_role;
revoke all on function public.lce_upload_ticket_valid(text) from public, anon, authenticated;
revoke all on function public.lce_consume_upload_ticket(text, text) from public, anon, authenticated;
grant execute on function public.lce_upload_ticket_valid(text) to service_role;
grant execute on function public.lce_consume_upload_ticket(text, text) to service_role;

-- Retire the SB-497 static token: overwrite its Vault value with fresh random bytes, generated
-- here and never rendered anywhere. Nothing reads it any more (v4 does not call the matcher).
select vault.update_secret(s.id, encode(extensions.gen_random_bytes(32), 'base64'))
  from vault.secrets s
 where s.name = 'lce_image_ingest_token';

-- Acceptance checks inside the migration.
do $$
declare v_bad text;
begin
  -- 1. client roles cannot execute any of the three functions (named, not via PUBLIC)
  select string_agg(format('%s->%s', routine_name, grantee), ', ') into v_bad
    from information_schema.routine_privileges
   where specific_schema = 'public'
     and routine_name in ('lce_issue_upload_tickets', 'lce_upload_ticket_valid', 'lce_consume_upload_ticket')
     and grantee in ('anon', 'authenticated', 'PUBLIC')
     and privilege_type = 'EXECUTE';
  if v_bad is not null then raise exception 'SB-650: client roles can execute ticket functions: %', v_bad; end if;

  -- 2. the service role can check and use tickets but cannot issue them
  if not has_function_privilege('service_role', 'public.lce_upload_ticket_valid(text)', 'EXECUTE')
     or not has_function_privilege('service_role', 'public.lce_consume_upload_ticket(text,text)', 'EXECUTE') then
    raise exception 'SB-650: service_role must be able to check and use tickets';
  end if;
  if has_function_privilege('service_role', 'public.lce_issue_upload_tickets(uuid,int)', 'EXECUTE') then
    raise exception 'SB-650: service_role must not be able to issue tickets';
  end if;

  -- 3. client roles have no privilege on the ticket table, and RLS is on with no policies
  if has_table_privilege('anon', 'public.lce_upload_tickets', 'SELECT')
     or has_table_privilege('authenticated', 'public.lce_upload_tickets', 'SELECT') then
    raise exception 'SB-650: client roles can read lce_upload_tickets';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.lce_upload_tickets'::regclass)
     or exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'lce_upload_tickets') then
    raise exception 'SB-650: lce_upload_tickets must have RLS on and no policies';
  end if;

  -- 4. null and garbage do not validate or consume; results are boolean only
  if public.lce_upload_ticket_valid(null) is not false or public.lce_upload_ticket_valid('lce-upl-nope') is not false
     or public.lce_consume_upload_ticket(null, null) is not false
     or public.lce_consume_upload_ticket('lce-upl-nope', 'lce-images/x/candidate-1.png') is not false then
    raise exception 'SB-650: an unknown or null ticket authenticated';
  end if;
  if pg_get_function_result('public.lce_upload_ticket_valid(text)'::regprocedure) <> 'boolean'
     or pg_get_function_result('public.lce_consume_upload_ticket(text,text)'::regprocedure) <> 'boolean' then
    raise exception 'SB-650: ticket check functions must return boolean only';
  end if;

  -- 5. the retired static token's secret still exists (overwritten, not removed)
  if (select count(*) from vault.secrets where name = 'lce_image_ingest_token') <> 1 then
    raise exception 'SB-650: lce_image_ingest_token secret missing';
  end if;
end $$;