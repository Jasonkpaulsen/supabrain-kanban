-- SB-650: one-time upload tickets for lce-image-ingest. TC-SB650-01 .. -04.
--
-- Run as postgres. One transaction that always ends by raising, so no fixture survives.
-- Pass = the raised message starts with "LCE_UPLOAD_TICKET PASS". The message carries counts,
-- verdicts and sqlstates only, never a ticket value.
-- Fixtures: image_requests rows on an existing article (one processing, one done, one failed, one
-- that goes done after issuing), and the tickets issued for them. Every step with a side effect
-- runs on its own line, in order (AND has no evaluation order).
-- The SB-650 verifier's mutation run found five mutants this suite missed (30-day expiry, issuing
-- for done/failed requests, consume revoked from service_role, search_path reset, RLS off); each
-- now has a check below.

do $suite$
declare
  ub constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';
  r jsonb := '{}'::jsonb; fails int; st text; n int; ok boolean; art uuid;
  rq uuid; rq_done uuid; rq_failed uuid; rq_late uuid;
  tix text[]; paths text[]; sets uuid[]; t1 text; t2 text; t3 text; t4 text; tl text; pl text;
  role_name text; q text;
begin
  execute $f$create or replace function pg_temp.t(q text) returns text language plpgsql as $b$
    begin execute q; return 'ok';
    exception when others then return case when sqlerrm like 'SB-650:%' then 'SB-650' else sqlstate end;
    end $b$$f$;

  select id into art from public.articles order by created_at limit 1;
  insert into public.image_requests (user_id, article_id, prompt, count, status)
  values (ub, art, 'qa-sb650 fixture', 3, 'pending') returning id into rq;
  insert into public.image_requests (user_id, article_id, prompt, count, status)
  values (ub, art, 'qa-sb650 fixture done', 3, 'done') returning id into rq_done;
  insert into public.image_requests (user_id, article_id, prompt, count, status)
  values (ub, art, 'qa-sb650 fixture failed', 3, 'failed') returning id into rq_failed;
  insert into public.image_requests (user_id, article_id, prompt, count, status)
  values (ub, art, 'qa-sb650 fixture late', 1, 'processing') returning id into rq_late;

  -- TC-SB650-01: issuing
  r := r || jsonb_build_object('TC-SB650-01.only_processing', case
         when pg_temp.t(format('select * from public.lce_issue_upload_tickets(%L, 3)', rq)) = 'SB-650'
              and pg_temp.t(format('select * from public.lce_issue_upload_tickets(%L, 3)', rq_done)) = 'SB-650'
              and pg_temp.t(format('select * from public.lce_issue_upload_tickets(%L, 3)', rq_failed)) = 'SB-650'
              and pg_temp.t(format('select * from public.lce_issue_upload_tickets(%L, 3)', gen_random_uuid())) = 'SB-650'
              and pg_temp.t('select * from public.lce_issue_upload_tickets(null, 3)') = 'SB-650'
         then 'pass' else 'FAIL' end);
  update public.image_requests set status = 'processing' where id = rq;
  r := r || jsonb_build_object('TC-SB650-01.count_bounds',
         case when pg_temp.t(format('select * from public.lce_issue_upload_tickets(%L, 0)', rq)) = 'SB-650'
                   and pg_temp.t(format('select * from public.lce_issue_upload_tickets(%L, 6)', rq)) = 'SB-650'
                   and pg_temp.t(format('select * from public.lce_issue_upload_tickets(%L, null)', rq)) = 'SB-650'
              then 'pass' else 'FAIL' end);
  select array_agg(x.ticket order by x.sort_order), array_agg(x.object_path order by x.sort_order), array_agg(distinct x.set_id)
    into tix, paths, sets
    from public.lce_issue_upload_tickets(rq, 4) x;
  r := r || jsonb_build_object('TC-SB650-01.issue_shape', case
         when array_length(tix, 1) = 4 and array_length(sets, 1) = 1
              and paths = array(select format('lce-images/%s/candidate-%s.png', sets[1], g) from generate_series(1, 4) g)
              and (select count(distinct x) from unnest(tix) x) = 4
              and (select bool_and(x ~ '^lce-upl-[0-9a-f]{48}$') from unnest(tix) x)
         then 'pass' else 'FAIL' end);
  r := r || jsonb_build_object('TC-SB650-01.expiry_30_minutes', case
         when (select bool_and(expires_at - created_at = interval '30 minutes') from public.lce_upload_tickets where request_id = rq)
         then 'pass' else 'FAIL' end);
  -- every issued path passes lce-image-ingest's allowlist (path.ts: segments of [A-Za-z0-9._-]+)
  r := r || jsonb_build_object('TC-SB650-01.paths_pass_allowlist', case
         when (select bool_and(seg ~ '^[A-Za-z0-9._-]+$' and seg not in ('.', '..')) from unnest(paths) p, unnest(string_to_array(p, '/')) seg)
         then 'pass' else 'FAIL' end);
  -- only the hash is stored: no column of any ticket row holds the plaintext
  select count(*) into n from public.lce_upload_tickets t, unnest(tix) x
   where t.request_id = rq and (position(x in t::text) > 0 or t.token_hash = convert_to(x, 'UTF8'));
  r := r || jsonb_build_object('TC-SB650-01.hash_only', case
         when n = 0 and (select count(*) from public.lce_upload_tickets t, unnest(tix) x
                          where t.token_hash = sha256(convert_to(x, 'UTF8'))) = 4
         then 'pass' else 'FAIL: plaintext found ' || n end);
  -- at most 15 tickets per request (4 issued so far): 5 + 5 + 1 fit, one more does not
  st := pg_temp.t(format('select * from public.lce_issue_upload_tickets(%L, 5)', rq));
  st := st || '/' || pg_temp.t(format('select * from public.lce_issue_upload_tickets(%L, 5)', rq));
  st := st || '/' || pg_temp.t(format('select * from public.lce_issue_upload_tickets(%L, 1)', rq));
  st := st || '/' || pg_temp.t(format('select * from public.lce_issue_upload_tickets(%L, 1)', rq));
  r := r || jsonb_build_object('TC-SB650-01.cap_15', case
         when st = 'ok/ok/ok/SB-650' and (select count(*) from public.lce_upload_tickets where request_id = rq) = 15
         then 'pass' else 'FAIL: ' || st end);

  -- TC-SB650-02: checking and using
  t1 := tix[1]; t2 := tix[2]; t3 := tix[3]; t4 := tix[4];
  r := r || jsonb_build_object('TC-SB650-02.valid_issued', case when public.lce_upload_ticket_valid(t1) then 'pass' else 'FAIL' end);
  r := r || jsonb_build_object('TC-SB650-02.invalid_inputs', case
         when public.lce_upload_ticket_valid(null) is false and public.lce_upload_ticket_valid('') is false
              and public.lce_upload_ticket_valid(upper(t1)) is false and public.lce_upload_ticket_valid(t1 || 'x') is false
         then 'pass' else 'FAIL' end);
  -- wrong or near-miss path: refused and the ticket stays usable
  ok := public.lce_consume_upload_ticket(t1, paths[2]);
  r := r || jsonb_build_object('TC-SB650-02.wrong_path', case
         when ok is false and public.lce_upload_ticket_valid(t1) then 'pass' else 'FAIL' end);
  r := r || jsonb_build_object('TC-SB650-02.near_miss_path', case
         when public.lce_consume_upload_ticket(t1, paths[1] || 'x') is false
              and public.lce_consume_upload_ticket(t1, upper(paths[1])) is false
              and public.lce_consume_upload_ticket(t1, null) is false
              and public.lce_upload_ticket_valid(t1)
         then 'pass' else 'FAIL' end);
  -- right path: used once, then never again
  ok := public.lce_consume_upload_ticket(t1, paths[1]);
  r := r || jsonb_build_object('TC-SB650-02.consume_once', case
         when ok is true and public.lce_upload_ticket_valid(t1) is false
              and public.lce_consume_upload_ticket(t1, paths[1]) is false
              and (select used_at is not null from public.lce_upload_tickets where object_path = paths[1])
         then 'pass' else 'FAIL' end);
  -- expired: neither valid nor usable
  update public.lce_upload_tickets set expires_at = now() - interval '1 second' where object_path = paths[2];
  r := r || jsonb_build_object('TC-SB650-02.expired', case
         when public.lce_upload_ticket_valid(t2) is false and public.lce_consume_upload_ticket(t2, paths[2]) is false
         then 'pass' else 'FAIL' end);
  -- a ticket cannot be used for another ticket's path even when both are live
  r := r || jsonb_build_object('TC-SB650-02.no_cross_path', case
         when public.lce_consume_upload_ticket(t3, paths[1]) is false and public.lce_upload_ticket_valid(t3)
         then 'pass' else 'FAIL' end);
  -- once its request is no longer processing, a live ticket stops working
  select x.ticket, x.object_path into tl, pl from public.lce_issue_upload_tickets(rq_late, 1) x;
  ok := public.lce_upload_ticket_valid(tl);
  update public.image_requests set status = 'done' where id = rq_late;
  r := r || jsonb_build_object('TC-SB650-02.dies_with_request', case
         when ok is true and public.lce_upload_ticket_valid(tl) is false and public.lce_consume_upload_ticket(tl, pl) is false
         then 'pass' else 'FAIL' end);

  -- TC-SB650-03: who can call what, tested as each role. Calls are caught inline, not through
  -- pg_temp.t: a function created by postgres grants no EXECUTE to client roles (SB-488), so the
  -- helper itself would be refused before the call under test ran.
  foreach role_name in array array['anon', 'authenticated', 'service_role'] loop
    st := '';
    execute format('set local role %I', role_name);
    foreach q in array array[
        format('select * from public.lce_issue_upload_tickets(%L, 1)', rq),
        format('select public.lce_upload_ticket_valid(%L)', t3),
        'select count(*) from public.lce_upload_tickets',
        'update public.lce_upload_tickets set used_at = null',
        format('select public.lce_image_ingest_token_matches(%L)', 'x')] loop
      begin
        execute q; st := st || 'ok,';
      exception when others then st := st || sqlstate || ',';
      end;
    end loop;
    -- client roles try t3 (must be refused); the service role uses t4 (must succeed: v4 depends on it)
    begin
      if role_name = 'service_role' then
        execute format('select public.lce_consume_upload_ticket(%L, %L)', t4, paths[4]) into ok;
        st := st || case when ok then 'consumed' else 'refused' end;
      else
        execute format('select public.lce_consume_upload_ticket(%L, %L)', t3, paths[3]); st := st || 'ok';
      end if;
    exception when others then st := st || sqlstate;
    end;
    execute 'reset role';
    r := r || jsonb_build_object('TC-SB650-03.' || role_name, case
           when role_name <> 'service_role' and st = '42501,42501,42501,42501,42501,42501' then 'pass'
           -- the service role (the edge function) checks and uses tickets, but cannot issue them
           -- or read or change the table (SB-650 hardening); it still has the retired matcher,
           -- which v3 calls until v4 is deployed
           when role_name = 'service_role' and st = '42501,ok,42501,42501,ok,consumed' then 'pass'
           else 'FAIL: ' || st end);
  end loop;
  r := r || jsonb_build_object('TC-SB650-03.refusals_consumed_nothing', case
         when public.lce_upload_ticket_valid(t3) and public.lce_upload_ticket_valid(t4) is false then 'pass' else 'FAIL' end);
  -- the functions keep SECURITY DEFINER and an empty search_path; the table keeps RLS with no policies
  r := r || jsonb_build_object('TC-SB650-03.definer_config', case
         when (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                where ns.nspname = 'public'
                  and p.proname in ('lce_issue_upload_tickets', 'lce_upload_ticket_valid', 'lce_consume_upload_ticket')
                  and p.prosecdef and p.proconfig = array['search_path=""']) = 3
              and (select relrowsecurity from pg_class where oid = 'public.lce_upload_tickets'::regclass)
              and not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'lce_upload_tickets')
         then 'pass' else 'FAIL' end);

  -- TC-SB650-04: the static token is retired
  r := r || jsonb_build_object('TC-SB650-04.vault_overwritten', case
         when (select updated_at >= '2026-10-28 03:00+00' from vault.secrets where name = 'lce_image_ingest_token')
              and public.lce_image_ingest_token_matches('definitely-not-the-token') is false
              and public.lce_image_ingest_token_matches(null) is false
         then 'pass' else 'FAIL' end);

  select count(*) into fails from jsonb_each_text(r) where value <> 'pass';
  if fails = 0 then
    raise exception 'LCE_UPLOAD_TICKET PASS (% checks) %', (select count(*) from jsonb_object_keys(r)), r;
  else
    raise exception 'LCE_UPLOAD_TICKET FAIL (% of % checks) %', fails, (select count(*) from jsonb_object_keys(r)), r;
  end if;
end
$suite$;
