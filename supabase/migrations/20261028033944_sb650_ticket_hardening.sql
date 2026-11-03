-- SB-650 verification fixes, before lce-image-ingest v4 is deployed.
--
-- 1. The service role had full table rights on lce_upload_tickets through Supabase's default
--    privileges, so the service-role key could insert a ticket hash of its own choosing or clear
--    used_at to revive a used ticket. v4 needs only the two SECURITY DEFINER functions, so the
--    table privileges go. Revoked by role name (SB-488 note in supabase/migrations/README.md).
-- 2. The 15-per-request cap was count-then-insert with no lock; two concurrent issue calls for one
--    request could exceed it. Issuing now locks the request row first.
-- 3. A ticket stayed usable after its request was marked done or failed. Checking and using a
--    ticket now also requires its request to still be 'processing' (tickets with no request, such
--    as smoke-probe fixtures, are unaffected).

revoke all on table public.lce_upload_tickets from service_role;

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
  -- lock the request so concurrent calls cannot both pass the cap check
  perform 1 from public.image_requests r where r.id = p_request_id and r.status = 'processing' for update;
  if not found then
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
                    and t.expires_at > now()
                    and (t.request_id is null
                         or exists (select 1 from public.image_requests r
                                     where r.id = t.request_id and r.status = 'processing')))
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
     and (t.request_id is null
          or exists (select 1 from public.image_requests r
                      where r.id = t.request_id and r.status = 'processing'))
  returning t.id into v_id;
  return v_id is not null;
end
$function$;

-- create or replace keeps existing grants; restate them so this file stands on its own
revoke all on function public.lce_issue_upload_tickets(uuid, int) from public, anon, authenticated, service_role;
revoke all on function public.lce_upload_ticket_valid(text) from public, anon, authenticated;
revoke all on function public.lce_consume_upload_ticket(text, text) from public, anon, authenticated;
grant execute on function public.lce_upload_ticket_valid(text) to service_role;
grant execute on function public.lce_consume_upload_ticket(text, text) to service_role;

do $$
begin
  if has_table_privilege('service_role', 'public.lce_upload_tickets', 'SELECT')
     or has_table_privilege('service_role', 'public.lce_upload_tickets', 'INSERT')
     or has_table_privilege('service_role', 'public.lce_upload_tickets', 'UPDATE') then
    raise exception 'SB-650: service_role still has table privileges on lce_upload_tickets';
  end if;
  if not has_function_privilege('service_role', 'public.lce_upload_ticket_valid(text)', 'EXECUTE')
     or not has_function_privilege('service_role', 'public.lce_consume_upload_ticket(text,text)', 'EXECUTE')
     or has_function_privilege('service_role', 'public.lce_issue_upload_tickets(uuid,int)', 'EXECUTE') then
    raise exception 'SB-650: function grants for service_role are wrong';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public'
                and p.proname in ('lce_issue_upload_tickets', 'lce_upload_ticket_valid', 'lce_consume_upload_ticket')
                and (not p.prosecdef or p.proconfig is distinct from array['search_path=""'])) then
    raise exception 'SB-650: a ticket function lost SECURITY DEFINER or its empty search_path';
  end if;
end $$;