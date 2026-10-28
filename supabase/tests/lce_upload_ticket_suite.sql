-- SB-650: one-time upload tickets for lce-image-ingest. TC-SB650-01 .. -04.
--
-- Run as postgres. One transaction that always ends by raising, so no fixture survives.
-- Pass = the raised message starts with "LCE_UPLOAD_TICKET PASS". The message carries counts,
-- verdicts and sqlstates only, never a ticket value.
-- Fixtures: one image_requests row on an existing article, and the tickets issued for it. Every
-- step with a side effect runs on its own line, in order (AND has no evaluation order).

do $suite$
declare
  ub constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';
  r jsonb := '{}'::jsonb; fails int; st text; n int; ok boolean;
  rq uuid; tix text[]; paths text[]; sets uuid[]; t1 text; t2 text; t3 text; role_name text; q text;
begin
  execute $f$create or replace function pg_temp.t(q text) returns text language plpgsql as $b$
    begin execute q; return 'ok';
    exception when others then return case when sqlerrm like 'SB-650:%' then 'SB-650' else sqlstate end;
    end $b$$f$;

  insert into public.image_requests (user_id, article_id, prompt, count, status)
  values (ub, (select id from public.articles order by created_at limit 1), 'qa-sb650 fixture', 3, 'pending')
  returning id into rq;

  -- TC-SB650-01: issuing
  r := r || jsonb_build_object('TC-SB650-01.pending_refused',
         case when pg_temp.t(format('select * from public.lce_issue_upload_tickets(%L, 3)', rq)) = 'SB-650' then 'pass' else 'FAIL' end);
  update public.image_requests set status = 'processing' where id = rq;
  r := r || jsonb_build_object('TC-SB650-01.count_bounds',
         case when pg_temp.t(format('select * from public.lce_issue_upload_tickets(%L, 0)', rq)) = 'SB-650'
                   and pg_temp.t(format('select * from public.lce_issue_upload_tickets(%L, 6)', rq)) = 'SB-650'
                   and pg_temp.t(format('select * from public.lce_issue_upload_tickets(%L, null)', rq)) = 'SB-650'
              then 'pass' else 'FAIL' end);
  select array_agg(x.ticket order by x.sort_order), array_agg(x.object_path order by x.sort_order), array_agg(distinct x.set_id)
    into tix, paths, sets
    from public.lce_issue_upload_tickets(rq, 3) x;
  r := r || jsonb_build_object('TC-SB650-01.issue_shape', case
         when array_length(tix, 1) = 3 and array_length(sets, 1) = 1
              and paths = array[format('lce-images/%s/candidate-1.png', sets[1]), format('lce-images/%s/candidate-2.png', sets[1]),
                                format('lce-images/%s/candidate-3.png', sets[1])]
              and (select count(distinct x) from unnest(tix) x) = 3
              and (select bool_and(x ~ '^lce-upl-[0-9a-f]{48}$') from unnest(tix) x)
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
                          where t.token_hash = sha256(convert_to(x, 'UTF8'))) = 3
         then 'pass' else 'FAIL: plaintext found ' || n end);
  -- at most 15 tickets per request (3 issued so far): 5 + 5 + 2 fit, one more does not
  st := pg_temp.t(format('select * from public.lce_issue_upload_tickets(%L, 5)', rq));
  st := st || '/' || pg_temp.t(format('select * from public.lce_issue_upload_tickets(%L, 5)', rq));
  st := st || '/' || pg_temp.t(format('select * from public.lce_issue_upload_tickets(%L, 2)', rq));
  st := st || '/' || pg_temp.t(format('select * from public.lce_issue_upload_tickets(%L, 1)', rq));
  r := r || jsonb_build_object('TC-SB650-01.cap_15', case
         when st = 'ok/ok/ok/SB-650' and (select count(*) from public.lce_upload_tickets where request_id = rq) = 15
         then 'pass' else 'FAIL: ' || st end);

  -- TC-SB650-02: checking and using
  t1 := tix[1]; t2 := tix[2]; t3 := tix[3];
  r := r || jsonb_build_object('TC-SB650-02.valid_issued', case when public.lce_upload_ticket_valid(t1) then 'pass' else 'FAIL' end);
  r := r || jsonb_build_object('TC-SB650-02.invalid_inputs', case
         when public.lce_upload_ticket_valid(null) is false and public.lce_upload_ticket_valid('') is false
              and public.lce_upload_ticket_valid(upper(t1)) is false and public.lce_upload_ticket_valid(t1 || 'x') is false
         then 'pass' else 'FAIL' end);
  -- wrong path: refused and the ticket stays usable
  ok := public.lce_consume_upload_ticket(t1, paths[2]);
  r := r || jsonb_build_object('TC-SB650-02.wrong_path', case
         when ok is false and public.lce_upload_ticket_valid(t1) then 'pass' else 'FAIL' end);
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

  -- TC-SB650-03: who can call what, tested as each role. The calls are caught inline, not through
  -- pg_temp.t: a function created by postgres grants no EXECUTE to client roles (SB-488), so the
  -- helper itself would be refused before the call under test ran.
  foreach role_name in array array['anon', 'authenticated', 'service_role'] loop
    st := '';
    execute format('set local role %I', role_name);
    foreach q in array array[
        format('select * from public.lce_issue_upload_tickets(%L, 1)', rq),
        format('select public.lce_upload_ticket_valid(%L)', t3),
        'select count(*) from public.lce_upload_tickets'] loop
      begin
        execute q; st := st || 'ok,';
      exception when others then st := st || sqlstate || ',';
      end;
    end loop;
    -- consume only for client roles: a successful consume by service_role would use up t3
    if role_name <> 'service_role' then
      begin
        execute format('select public.lce_consume_upload_ticket(%L, %L)', t3, paths[3]); st := st || 'ok';
      exception when others then st := st || sqlstate;
      end;
    end if;
    execute 'reset role';
    r := r || jsonb_build_object('TC-SB650-03.' || role_name, case
           when role_name <> 'service_role' and st = '42501,42501,42501,42501' then 'pass'
           -- the service role (the edge function) checks tickets but cannot issue them; it bypasses
           -- RLS on the table, as it does everywhere
           when role_name = 'service_role' and st = '42501,ok,ok,' then 'pass'
           else 'FAIL: ' || st end);
  end loop;
  -- the ticket used in the checks above is still live: no role's refused call consumed it
  r := r || jsonb_build_object('TC-SB650-03.refusals_consumed_nothing', case
         when public.lce_upload_ticket_valid(t3) then 'pass' else 'FAIL' end);

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
