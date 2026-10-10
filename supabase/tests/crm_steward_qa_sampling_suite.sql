-- CRM steward QA sampling suite: TC-SB575-1..15 and 17 (SB-575; ADR-CRM-006 §7, SB-575 amendment).
-- TC-SB575-16 is the regression run of the other steward suites (recorded separately).
--
-- Covers crm_steward_qa_sample (merges first, never twice, 7-day window for non-merges, weekly
-- idempotency, size clamp, ticket with ids only), crm_steward_record_verdict (2% threshold over the
-- latest verdict of the last 50 merge decisions, supersession, only merges count, no duplicate
-- suspend, re-suspend after resume, refusals, owner isolation) and the weekly schedule
-- (crm_steward_scheduled('weekly') through the exact text of the crm-steward-weekly cron job).
--
-- Runs as postgres, acting as two signed-in users: ua (fixture tenant; its decision rows are
-- synthetic, inserted as postgres so created_at can be set) and ub (the owner; real steward and
-- sampler runs, a real SB ticket, all rolled back). One transaction that always ends by raising,
-- and every case also rolls back its own sub-block, so no decision, agent change, agent_runs row or
-- work_items ticket survives, and the owner's automation_enabled is never left on.
-- Pass = the raised message starts with "CRM-STEWARD-QA-SAMPLING PASS". The message carries only
-- counts, booleans, sqlstates and ids, never CRM names, emails or phones.

do $suite$
declare
  ua  constant uuid := '5ebab8fc-e993-4aee-bbc1-eb8ff08a2e0e';   -- fixture tenant
  ub  constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';   -- owner
  aid constant uuid := '35c61865-2677-42fd-aad3-d2aa8fa81e85';   -- owner's CRM Data Steward
  sb  constant uuid := 'a07a7f3d-722f-468f-81fa-84e2c5fba704';   -- SB project
  md5_sample    constant text := '2db52bfdf26524e54c5db71795bf9b8c';
  md5_verdict   constant text := '614c68654a54ae4b9b79006b46328b9d';   -- after 20261009032904 (suspend only on a wrong merge verdict)
  md5_scheduled constant text := '018a00808c60d53efc0c8f819bef72cc';   -- after 20261009034206 (SB-574 adds the digest to 'weekly')
  rb  constant text := '__sb575_rollback__';
  r jsonb := '{}'::jsonb;
  n int; m int; k int; i int; fails int; st text; msg text; txt text; cmd text;
  mg uuid[]; nm uuid[]; old uuid[]; ids uuid[]; p1 uuid; p2 uuid;
  res jsonb; res2 jsonb; a jsonb; b jsonb; c jsonb; d jsonb;
  st_a text; st_b text; st_c text; st_d text; st_e text; st_f text; st_g text; st_h text; st_i text;
  wi public.work_items%rowtype; ar public.agent_runs%rowtype;
  runs0 int; runs1 int; rc0 int; rc1 int; wi0 int; wi1 int; dec0 int; dec1 int;
  cu text; uid uuid; ub_dec uuid; epic uuid;
begin
  -- fixture tenant must be empty
  if exists (select 1 from public.crm_steward_decisions where user_id = ua)
     or exists (select 1 from public.crm_people where user_id = ua) then
    raise exception 'CRM-STEWARD-QA-SAMPLING FAIL: fixture tenant is not empty';
  end if;
  select d.id into ub_dec from public.crm_steward_decisions d where d.user_id = ub and d.decision like 'auto_%' limit 1;
  select w.id into epic from public.work_items w where w.ticket_code = 'SB-570';

  -- ------------------------------------------------ TC-SB575-1: 1 wrong in 50 is not a suspension; 1 in 49 is
  begin
    begin
      with x as (insert into public.crm_steward_decisions (user_id, actor_id, decision, rule, entity_type, entity_id, reason_code)
                 select ua, ua, 'auto_merge', 'auto_merge_contact', 'crm_people', gen_random_uuid(), 'qa_fixture'
                   from generate_series(1, 60) returning id, seq)
      select array_agg(id order by seq) into mg from x;
      perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
      set local role authenticated;
      for i in 1 .. 49 loop res := public.crm_steward_record_verdict(mg[i], 'correct'); end loop;
      a := public.crm_steward_record_verdict(mg[50], 'wrong');
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then a := jsonb_build_object('error', sqlstate || ' ' || sqlerrm); end if;
    end;
    begin
      with x as (insert into public.crm_steward_decisions (user_id, actor_id, decision, rule, entity_type, entity_id, reason_code)
                 select ua, ua, 'auto_merge', 'auto_merge_contact', 'crm_people', gen_random_uuid(), 'qa_fixture'
                   from generate_series(1, 60) returning id, seq)
      select array_agg(id order by seq) into mg from x;
      perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
      set local role authenticated;
      for i in 1 .. 48 loop res := public.crm_steward_record_verdict(mg[i], 'correct'); end loop;
      b := public.crm_steward_record_verdict(mg[49], 'wrong');
      select count(*) into n from public.crm_steward_decisions where decision = 'suspend' and rule = 'qa_wrong_merge_rate';
      b := b || jsonb_build_object('suspend_rows', n,
             'refers_ok', exists (select 1 from public.crm_steward_decisions s where s.decision = 'suspend'
                                   and s.refers_to = (b->>'verdict_id')::uuid and s.entity_id = (b->>'verdict_id')::uuid
                                   and s.reason_code = 'qa_suspend'));
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then b := jsonb_build_object('error', sqlstate || ' ' || sqlerrm); end if;
    end;
    r := r || jsonb_build_object('TC-SB575-1', case
           when (a->>'merge_verdicts')::int = 50 and (a->>'wrong_merges')::int = 1 and (a->>'wrong_merge_rate')::numeric = 0.02
            and not (a->>'suspended_now')::boolean and not (a->>'suspended')::boolean
            and (b->>'merge_verdicts')::int = 49 and (b->>'wrong_merges')::int = 1
            and (b->>'suspended_now')::boolean and (b->>'suspended')::boolean
            and (b->>'suspend_rows')::int = 1 and (b->>'refers_ok')::boolean
           then 'pass' else format('FAIL: 1/50 %s | 1/49 %s', a - 'verdict_id', b - 'verdict_id') end);
  end;

  -- ------------------------------------------------ TC-SB575-2: 2 in 50 suspends; a correct->wrong supersession counts
  begin
    begin
      with x as (insert into public.crm_steward_decisions (user_id, actor_id, decision, rule, entity_type, entity_id, reason_code)
                 select ua, ua, 'auto_merge', 'auto_merge_contact', 'crm_people', gen_random_uuid(), 'qa_fixture'
                   from generate_series(1, 60) returning id, seq)
      select array_agg(id order by seq) into mg from x;
      perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
      set local role authenticated;
      for i in 1 .. 49 loop res := public.crm_steward_record_verdict(mg[i], 'correct'); end loop;
      a := public.crm_steward_record_verdict(mg[50], 'wrong');          -- 1/50: no
      b := public.crm_steward_record_verdict(mg[1], 'wrong', 'qa_rereview');  -- m1 correct -> wrong: 2/50
      r := r || jsonb_build_object('TC-SB575-2', case
             when not (a->>'suspended_now')::boolean
              and (b->>'merge_verdicts')::int = 50 and (b->>'wrong_merges')::int = 2 and (b->>'wrong_merge_rate')::numeric = 0.04
              and (b->>'suspended_now')::boolean
             then 'pass' else format('FAIL: %s | %s', a - 'verdict_id', b - 'verdict_id') end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB575-2', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB575-3: wrong->correct supersession, and the window slides past 50
  begin
    begin
      with x as (insert into public.crm_steward_decisions (user_id, actor_id, decision, rule, entity_type, entity_id, reason_code)
                 select ua, ua, 'auto_merge', 'auto_merge_contact', 'crm_people', gen_random_uuid(), 'qa_fixture'
                   from generate_series(1, 60) returning id, seq)
      select array_agg(id order by seq) into mg from x;
      perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
      set local role authenticated;
      for i in 1 .. 49 loop res := public.crm_steward_record_verdict(mg[i], 'correct'); end loop;
      a := public.crm_steward_record_verdict(mg[50], 'wrong');      -- 1/50
      b := public.crm_steward_record_verdict(mg[50], 'correct');    -- superseded: 0/50, not 1/51
      c := public.crm_steward_record_verdict(mg[51], 'wrong');      -- m1 slides out: 1/50
      d := public.crm_steward_record_verdict(mg[52], 'correct');    -- m2 slides out: still 1/50
      select count(*) into n from public.crm_steward_decisions where decision = 'suspend';
      r := r || jsonb_build_object('TC-SB575-3.a', case
             when (b->>'merge_verdicts')::int = 50 and (b->>'wrong_merges')::int = 0
              and (c->>'merge_verdicts')::int = 50 and (c->>'wrong_merges')::int = 1 and not (c->>'suspended_now')::boolean
              and (d->>'merge_verdicts')::int = 50 and (d->>'wrong_merges')::int = 1 and n = 0
             then 'pass' else format('FAIL: %s | %s | %s suspends %s', b - 'verdict_id', c - 'verdict_id', d - 'verdict_id', n) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB575-3.a', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
    -- a wrong verdict slides out of the window after 50 newer merge verdicts
    begin
      with x as (insert into public.crm_steward_decisions (user_id, actor_id, decision, rule, entity_type, entity_id, reason_code)
                 select ua, ua, 'auto_merge', 'auto_merge_contact', 'crm_people', gen_random_uuid(), 'qa_fixture'
                   from generate_series(1, 60) returning id, seq)
      select array_agg(id order by seq) into mg from x;
      perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
      set local role authenticated;
      a := public.crm_steward_record_verdict(mg[1], 'wrong');
      for i in 2 .. 50 loop res := public.crm_steward_record_verdict(mg[i], 'correct'); end loop;
      b := res;                                                     -- m1..m50: 1/50
      c := public.crm_steward_record_verdict(mg[51], 'correct');    -- m1 out: 0/50
      r := r || jsonb_build_object('TC-SB575-3.b', case
             when (a->>'suspended_now')::boolean
              and (b->>'merge_verdicts')::int = 50 and (b->>'wrong_merges')::int = 1
              and (c->>'merge_verdicts')::int = 50 and (c->>'wrong_merges')::int = 0
             then 'pass' else format('FAIL: %s | %s | %s', a - 'verdict_id', b - 'verdict_id', c - 'verdict_id') end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB575-3.b', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB575-4: only merges count; small samples
  begin
    begin
      with x as (insert into public.crm_steward_decisions (user_id, actor_id, decision, rule, entity_type, entity_id, reason_code)
                 select ua, ua, 'auto_merge', 'auto_merge_contact', 'crm_people', gen_random_uuid(), 'qa_fixture'
                   from generate_series(1, 10) returning id, seq)
      select array_agg(id order by seq) into mg from x;
      with x as (insert into public.crm_steward_decisions (user_id, actor_id, decision, rule, entity_type, entity_id, reason_code)
                 select ua, ua, (array['auto_confirm', 'auto_resolve', 'auto_expire', 'auto_dismiss', 'auto_confirm'])[g], 'qa_fixture_rule',
                        'crm_people', gen_random_uuid(), 'qa_fixture'
                   from generate_series(1, 5) g returning id, seq)
      select array_agg(id order by seq) into nm from x;
      perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
      set local role authenticated;
      a := public.crm_steward_record_verdict(nm[1], 'wrong');        -- no merge verdicts at all
      for i in 2 .. 5 loop res := public.crm_steward_record_verdict(nm[i], 'wrong'); end loop;
      for i in 1 .. 10 loop res := public.crm_steward_record_verdict(mg[i], 'correct'); end loop;
      b := res;                                                      -- 0/10 merges, 5 wrong non-merges
      select count(*) into n from public.crm_steward_decisions where decision = 'suspend';
      c := public.crm_steward_record_verdict(mg[1], 'wrong');        -- 1/10 (fewer than 50): suspends
      r := r || jsonb_build_object('TC-SB575-4', case
             when (a->>'merge_verdicts')::int = 0 and a->>'wrong_merge_rate' is null and not (a->>'suspended_now')::boolean
              and (b->>'merge_verdicts')::int = 10 and (b->>'wrong_merges')::int = 0 and n = 0
              and (c->>'merge_verdicts')::int = 10 and (c->>'wrong_merges')::int = 1 and (c->>'suspended_now')::boolean
             then 'pass' else format('FAIL: %s | %s | suspends %s | %s', a - 'verdict_id', b - 'verdict_id', n, c - 'verdict_id') end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB575-4', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB575-5: no duplicate suspend; resume then a new wrong suspends again; nothing undone
  begin
    begin
      with x as (insert into public.crm_steward_decisions (user_id, actor_id, decision, rule, entity_type, entity_id, reason_code)
                 select ua, ua, 'auto_merge', 'auto_merge_contact', 'crm_people', gen_random_uuid(), 'qa_fixture'
                   from generate_series(1, 5) returning id, seq)
      select array_agg(id order by seq) into mg from x;
      select count(*) into dec0 from public.crm_merge_log;
      perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
      set local role authenticated;
      a := public.crm_steward_record_verdict(mg[1], 'wrong');
      b := public.crm_steward_record_verdict(mg[2], 'wrong');
      select count(*) into n from public.crm_steward_decisions where decision = 'suspend';
      insert into public.crm_steward_decisions (decision, rule, entity_type, reason_code)
        values ('resume', 'qa_reviewed', 'crm_steward_decisions', 'qa_resume');
      k := public.crm_steward_suspended()::int;
      c := public.crm_steward_record_verdict(mg[3], 'wrong');
      select count(*) into m from public.crm_steward_decisions where decision = 'suspend';
      reset role;
      select count(*) into dec1 from public.crm_merge_log;
      select count(*) into i from public.crm_steward_decisions
       where user_id = ua and decision not in ('auto_merge', 'qa_verdict', 'suspend', 'resume');
      r := r || jsonb_build_object('TC-SB575-5', case
             when (a->>'suspended_now')::boolean and not (b->>'suspended_now')::boolean and (b->>'suspended')::boolean and n = 1
              and k = 0 and (c->>'suspended_now')::boolean and m = 2 and dec1 = dec0 and i = 0
             then 'pass' else format('FAIL: first %s second %s suspends %s, after resume suspended %s, third %s suspends %s, merge_log %s->%s, other rows %s',
                                     a->'suspended_now', b->'suspended_now', n, k, c->'suspended_now', m, dec0, dec1, i) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB575-5', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB575-6: a resume survives correct verdicts and verdicts on non-merges
  -- After Jason resumes, the wrong verdict that tripped the suspension is still in the window (rate
  -- above 2%). Before 20261009032904 the next verdict of any kind re-suspended (QA D1). A resume must
  -- hold until a NEW wrong merge verdict arrives.
  begin
    begin
      with x as (insert into public.crm_steward_decisions (user_id, actor_id, decision, rule, entity_type, entity_id, reason_code)
                 select ua, ua, 'auto_merge', 'auto_merge_contact', 'crm_people', gen_random_uuid(), 'qa_fixture'
                   from generate_series(1, 5) returning id, seq)
      select array_agg(id order by seq) into mg from x;
      insert into public.crm_steward_decisions (user_id, actor_id, decision, rule, entity_type, entity_id, reason_code)
        values (ua, ua, 'auto_confirm', 'tier_a', 'crm_people', gen_random_uuid(), 'qa_fixture') returning id into p1;
      perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
      set local role authenticated;
      a := public.crm_steward_record_verdict(mg[1], 'wrong');                     -- suspends
      insert into public.crm_steward_decisions (decision, rule, entity_type, reason_code)
        values ('resume', 'qa_reviewed', 'crm_steward_decisions', 'qa_resume');  -- Jason resumes
      b := public.crm_steward_record_verdict(mg[2], 'correct');                   -- a correct merge verdict
      c := public.crm_steward_record_verdict(p1, 'correct');                      -- a correct verdict on a non-merge
      d := public.crm_steward_record_verdict(p1, 'wrong');                        -- a wrong verdict on a non-merge
      k := public.crm_steward_suspended()::int;
      res := public.crm_steward_record_verdict(mg[3], 'wrong');                   -- a new wrong merge: suspends again
      r := r || jsonb_build_object('TC-SB575-6', case
             when (a->>'suspended_now')::boolean and not (b->>'suspended_now')::boolean and not (c->>'suspended_now')::boolean
              and not (d->>'suspended_now')::boolean and k = 0 and (b->>'wrong_merge_rate')::numeric > 0.02
              and (res->>'suspended_now')::boolean
             then 'pass' else format('FAIL: after resume re-suspended by: correct merge %s, correct non-merge %s, wrong non-merge %s; suspended %s (rate %s); new wrong merge suspends %s',
                                     b->'suspended_now', c->'suspended_now', d->'suspended_now', k, b->'wrong_merge_rate', res->'suspended_now') end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB575-6', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB575-17: after a resume, correct verdicts slide the old wrong out; boundaries still hold
  begin
    begin
      with x as (insert into public.crm_steward_decisions (user_id, actor_id, decision, rule, entity_type, entity_id, reason_code)
                 select ua, ua, 'auto_merge', 'auto_merge_contact', 'crm_people', gen_random_uuid(), 'qa_fixture'
                   from generate_series(1, 60) returning id, seq)
      select array_agg(id order by seq) into mg from x;
      perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
      set local role authenticated;
      a := public.crm_steward_record_verdict(mg[1], 'wrong');                     -- 1/1: suspends
      insert into public.crm_steward_decisions (decision, rule, entity_type, reason_code)
        values ('resume', 'qa_reviewed', 'crm_steward_decisions', 'qa_resume');
      for i in 2 .. 51 loop res := public.crm_steward_record_verdict(mg[i], 'correct'); end loop;
      b := res;                                                                   -- m1 slid out: 0/50
      select count(*) into n from public.crm_steward_decisions where decision = 'suspend';
      k := public.crm_steward_suspended()::int;
      c := public.crm_steward_record_verdict(mg[52], 'wrong');                    -- 1/50 = 2%: no suspend
      d := public.crm_steward_record_verdict(mg[53], 'wrong');                    -- 2/50: suspends
      select count(*) into m from public.crm_steward_decisions where decision = 'suspend';
      r := r || jsonb_build_object('TC-SB575-17', case
             when (a->>'suspended_now')::boolean and n = 1 and k = 0
              and (b->>'merge_verdicts')::int = 50 and (b->>'wrong_merges')::int = 0 and not (b->>'suspended')::boolean
              and (c->>'merge_verdicts')::int = 50 and (c->>'wrong_merges')::int = 1 and not (c->>'suspended_now')::boolean
              and (d->>'merge_verdicts')::int = 50 and (d->>'wrong_merges')::int = 2 and (d->>'suspended_now')::boolean and m = 2
             then 'pass' else format('FAIL: first %s; suspends during slide %s, suspended %s; after slide %s; 1/50 %s; 2/50 %s; suspends %s',
                                     a->'suspended_now', n, k, b - 'verdict_id', c - 'verdict_id', d - 'verdict_id', m) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB575-17', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB575-7: verdict and sampler refusals, owner isolation
  begin
    begin
      with x as (insert into public.crm_steward_decisions (user_id, actor_id, decision, rule, entity_type, entity_id, reason_code)
                 select ua, ua, 'auto_merge', 'auto_merge_contact', 'crm_people', gen_random_uuid(), 'qa_fixture'
                   from generate_series(1, 2) returning id, seq)
      select array_agg(id order by seq) into mg from x;
      insert into public.crm_steward_decisions (user_id, actor_id, decision, rule, entity_type, entity_id, reason_code, refers_to)
        values (ua, ua, 'qa_sample', 'weekly_sample', 'crm_steward_decisions', mg[1], 'qa_sample', mg[1]) returning id into p1;
      insert into public.crm_steward_decisions (user_id, actor_id, decision, rule, entity_type, reason_code)
        values (ua, ua, 'resume', 'qa_reviewed', 'crm_steward_decisions', 'qa_resume') returning id into p2;
      perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
      set local role authenticated;
      res := public.crm_steward_record_verdict(mg[2], 'wrong');                  -- writes a qa_verdict and a suspend row
      select count(*) into dec0 from public.crm_steward_decisions;
      st_a := 'ok'; begin perform public.crm_steward_record_verdict(mg[1], 'WRONG'); exception when others then st_a := sqlstate; end;
      st_b := 'ok'; begin perform public.crm_steward_record_verdict(mg[1], null); exception when others then st_b := sqlstate; end;
      st_c := 'ok'; begin perform public.crm_steward_record_verdict(p1, 'correct'); exception when others then st_c := sqlstate; end;   -- qa_sample
      st_d := 'ok'; begin perform public.crm_steward_record_verdict((res->>'verdict_id')::uuid, 'correct'); exception when others then st_d := sqlstate; end;  -- qa_verdict
      st_e := 'ok'; begin perform public.crm_steward_record_verdict(p2, 'correct'); exception when others then st_e := sqlstate; end;   -- resume
      st_f := 'ok'; begin perform public.crm_steward_record_verdict(gen_random_uuid(), 'correct'); exception when others then st_f := sqlstate; end;
      st_g := 'ok'; begin perform public.crm_steward_record_verdict(ub_dec, 'wrong'); exception when others then st_g := sqlstate; end;  -- owner's decision, as ua
      st_h := 'ok'; begin perform public.crm_steward_record_verdict(null, 'wrong'); exception when others then st_h := sqlstate; end;
      select count(*) into dec1 from public.crm_steward_decisions;
      -- suspend rows: also one on the suspend row itself must be refused
      select id into p2 from public.crm_steward_decisions where decision = 'suspend' limit 1;
      st_i := 'ok'; begin perform public.crm_steward_record_verdict(p2, 'correct'); exception when others then st_i := sqlstate; end;
      -- no auth
      perform set_config('request.jwt.claims', '', true);
      perform set_config('request.jwt.claim.sub', '', true);
      msg := '';
      begin perform public.crm_steward_record_verdict(mg[1], 'correct'); msg := msg || 'v:ok '; exception when others then msg := msg || 'v:' || sqlstate || ' '; end;
      begin perform public.crm_steward_qa_sample(5); msg := msg || 's:ok'; exception when others then msg := msg || 's:' || sqlstate; end;
      -- anon
      set local role anon;
      begin perform public.crm_steward_record_verdict(mg[1], 'correct'); msg := msg || ' av:ok'; exception when others then msg := msg || ' av:' || sqlstate; end;
      begin perform public.crm_steward_qa_sample(5); msg := msg || ' as:ok'; exception when others then msg := msg || ' as:' || sqlstate; end;
      reset role;
      -- owner isolation: the owner's suspension is untouched by ua's suspend, and ua's rows are invisible to ub
      perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
      set local role authenticated;
      k := public.crm_steward_suspended()::int;
      select count(*) into n from public.crm_steward_decisions where user_id = ua;
      reset role;
      r := r || jsonb_build_object('TC-SB575-7', case
             when st_a = '22023' and st_b = '22023' and st_c = '22023' and st_d = '22023' and st_e = '22023'
              and st_f = '22023' and st_g = '22023' and st_h = '22023' and st_i = '22023' and dec1 = dec0
              and msg = 'v:42501 s:42501 av:42501 as:42501' and k = 0 and n = 0 and ub_dec is not null
             then 'pass' else format('FAIL: bad verdict %s, null verdict %s, on qa_sample %s, on qa_verdict %s, on resume %s, unknown %s, other owner %s, null id %s, on suspend %s, rows %s->%s, auth [%s], ub suspended %s, ub sees ua rows %s',
                                     st_a, st_b, st_c, st_d, st_e, st_f, st_g, st_h, st_i, dec0, dec1, msg, k, n) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB575-7', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB575-8: sampler fairness: merges first, 7-day window, only own rows
  begin
    begin
      with x as (insert into public.crm_steward_decisions (user_id, actor_id, decision, rule, entity_type, entity_id, reason_code, created_at)
                 select ua, ua, 'auto_merge', 'auto_merge_contact', 'crm_people', gen_random_uuid(), 'qa_fixture',
                        case when g = 1 then now() - interval '30 days' else now() end
                   from generate_series(1, 3) g returning id, seq)
      select array_agg(id order by seq) into mg from x;
      with x as (insert into public.crm_steward_decisions (user_id, actor_id, decision, rule, entity_type, entity_id, reason_code, created_at)
                 select ua, ua, (array['auto_confirm', 'auto_resolve', 'auto_expire', 'auto_dismiss'])[1 + g % 4], 'qa_fixture_rule',
                        'crm_people', gen_random_uuid(), 'qa_fixture', now() - interval '6 days 23 hours'
                   from generate_series(1, 20) g returning id, seq)
      select array_agg(id order by seq) into nm from x;
      with x as (insert into public.crm_steward_decisions (user_id, actor_id, decision, rule, entity_type, entity_id, reason_code, created_at)
                 select ua, ua, 'auto_confirm', 'qa_fixture_rule', 'crm_people', gen_random_uuid(), 'qa_fixture', now() - interval '8 days'
                   from generate_series(1, 5) g returning id, seq)
      select array_agg(id order by seq) into old from x;
      perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
      set local role authenticated;
      a := public.crm_steward_qa_sample(10);
      select array_agg(refers_to) into ids from public.crm_steward_decisions where decision = 'qa_sample';
      b := public.crm_steward_qa_sample(10);                         -- same week: skipped
      select count(*) into n from public.crm_steward_decisions where decision = 'qa_sample';
      reset role;
      select count(*) into m from public.crm_steward_decisions s
       where s.decision = 'qa_sample' and s.user_id = ua and s.run_id = (a->>'run_id')::uuid
         and s.entity_id = s.refers_to and s.rule = 'weekly_sample' and s.reason_code = 'qa_sample' and s.actor_id = ua;
      r := r || jsonb_build_object('TC-SB575-8', case
             when (a->>'sampled')::int = 10 and (a->>'merges')::int = 3 and a->'work_item' = 'null'::jsonb
              and cardinality(ids) = 10 and (select count(distinct x) from unnest(ids) x) = 10
              and ids @> mg and (select count(*) from unnest(ids) x where x = any(nm)) = 7
              and not (ids && old) and m = 10
              and not exists (select 1 from unnest(ids) x join public.crm_steward_decisions d on d.id = x where d.user_id <> ua)
              and (b->>'skipped')::boolean and n = 10
             then 'pass' else format('FAIL: first %s, picks %s (merges in %s, recent %s, old %s), rows ok %s, second %s, rows %s',
                                     a - 'run_id', cardinality(ids), ids @> mg, (select count(*) from unnest(ids) x where x = any(nm)),
                                     ids && old, m, b, n) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB575-8', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB575-9: never twice; the 6-day idempotency window
  begin
    begin
      with x as (insert into public.crm_steward_decisions (user_id, actor_id, decision, rule, entity_type, entity_id, reason_code)
                 select ua, ua, 'auto_merge', 'auto_merge_contact', 'crm_people', gen_random_uuid(), 'qa_fixture'
                   from generate_series(1, 4) returning id, seq)
      select array_agg(id order by seq) into mg from x;
      with x as (insert into public.crm_steward_decisions (user_id, actor_id, decision, rule, entity_type, entity_id, reason_code)
                 select ua, ua, 'auto_confirm', 'qa_fixture_rule', 'crm_people', gen_random_uuid(), 'qa_fixture'
                   from generate_series(1, 6) returning id, seq)
      select array_agg(id order by seq) into nm from x;
      -- last week's sample (7 days ago) covered 3 merges and 2 non-merges
      insert into public.crm_steward_decisions (user_id, actor_id, decision, rule, entity_type, entity_id, reason_code, refers_to, created_at)
      select ua, ua, 'qa_sample', 'weekly_sample', 'crm_steward_decisions', x, 'qa_sample', x, now() - interval '7 days'
        from unnest(array[mg[1], mg[2], mg[3], nm[1], nm[2]]) x;
      perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
      set local role authenticated;
      a := public.crm_steward_qa_sample(50);
      select array_agg(refers_to) into ids from public.crm_steward_decisions where decision = 'qa_sample' and run_id = (a->>'run_id')::uuid;
      reset role;
      r := r || jsonb_build_object('TC-SB575-9.a', case
             when (a->>'sampled')::int = 5 and (a->>'merges')::int = 1 and ids @> array[mg[4]]
              and not (ids && array[mg[1], mg[2], mg[3], nm[1], nm[2]])
             then 'pass' else format('FAIL: %s, resampled %s', a - 'run_id', ids && array[mg[1], mg[2], mg[3], nm[1], nm[2]]) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB575-9.a', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
    begin
      insert into public.crm_steward_decisions (user_id, actor_id, decision, rule, entity_type, entity_id, reason_code)
        values (ua, ua, 'auto_merge', 'auto_merge_contact', 'crm_people', gen_random_uuid(), 'qa_fixture') returning id into p1;
      insert into public.crm_steward_decisions (user_id, actor_id, decision, rule, entity_type, entity_id, reason_code, refers_to, created_at)
        values (ua, ua, 'qa_sample', 'weekly_sample', 'crm_steward_decisions', gen_random_uuid(), 'qa_sample', gen_random_uuid(), now() - interval '5 days 23 hours');
      perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
      set local role authenticated;
      a := public.crm_steward_qa_sample(10);                         -- a sample 5d23h ago: skipped
      reset role;
      r := r || jsonb_build_object('TC-SB575-9.b', case
             when (a->>'skipped')::boolean
              and not exists (select 1 from public.crm_steward_decisions where decision = 'qa_sample' and refers_to = p1)
             then 'pass' else format('FAIL: %s', a) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB575-9.b', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
      set local role authenticated;
      a := public.crm_steward_qa_sample(10);                         -- nothing eligible for ua
      select count(*) into n from public.crm_steward_decisions where decision = 'qa_sample';
      reset role;
      r := r || jsonb_build_object('TC-SB575-9.c', case
             when (a->>'sampled')::int = 0 and a->'work_item' = 'null'::jsonb and n = 0 then 'pass'
             else format('FAIL: %s rows %s', a - 'run_id', n) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB575-9.c', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB575-10: size clamp 1..50, default 10
  begin
    msg := '';
    foreach st in array array['0', '-5', 'null', '1000', '7', 'default'] loop
      begin
        insert into public.crm_steward_decisions (user_id, actor_id, decision, rule, entity_type, entity_id, reason_code)
        select ua, ua, 'auto_confirm', 'qa_fixture_rule', 'crm_people', gen_random_uuid(), 'qa_fixture' from generate_series(1, 60);
        perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
        set local role authenticated;
        a := case st when 'null' then public.crm_steward_qa_sample(null)
                     when 'default' then public.crm_steward_qa_sample()
                     else public.crm_steward_qa_sample(st::int) end;
        msg := msg || st || '=' || coalesce(a->>'sampled', 'x') || ' ';
        raise exception '%', rb;
      exception when others then
        if sqlerrm <> rb then msg := msg || st || '=error:' || sqlstate || ' '; end if;
      end;
    end loop;
    r := r || jsonb_build_object('TC-SB575-10', case
           when msg = '0=1 -5=1 null=10 1000=50 7=7 default=10 ' then 'pass' else 'FAIL: ' || msg end);
  end;

  -- ------------------------------------------------ TC-SB575-11: owner sample opens one SB ticket with ids only
  begin
    begin
      update public.agents set automation_enabled = true where id = aid and status = 'active';
      perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
      set local role authenticated;
      -- three fixture duplicate pairs (same surname, shared fixture email) so the real run makes merges with undo handles
      for i in 1 .. 3 loop
        insert into public.crm_people (display_name, family_name) values (format('Quennell Zarbock%s', i), format('Zarbock%s', i)) returning id into p1;
        insert into public.crm_people (display_name, family_name) values (format('Ysmay Zarbock%s', i), format('Zarbock%s', i)) returning id into p2;
        insert into public.crm_contact_points (person_id, kind, value)
          values (p1, 'email', format('sb575-%s@zq.example', i)), (p2, 'email', format('sb575-%s@zq.example', i));
      end loop;
      res := public.crm_steward_run(false);
      select count(*) into wi0 from public.work_items where meta->>'issue_type' = 'crm_steward_qa_sample';
      a := public.crm_steward_qa_sample(10);
      select count(*) into wi1 from public.work_items where meta->>'issue_type' = 'crm_steward_qa_sample';
      select * into wi from public.work_items where id = (a->>'work_item')::uuid;
      select array_agg(refers_to) into ids from public.crm_steward_decisions where decision = 'qa_sample' and run_id = (a->>'run_id')::uuid;
      txt := lower(coalesce(wi.title, '') || ' ' || coalesce(wi.description, '') || ' ' || coalesce(wi.meta::text, ''));
      -- every sampled id and every merge undo handle is in the text
      select count(*) into n from unnest(ids) x where strpos(txt, x::text) > 0;
      select count(*) into m from public.crm_steward_decisions d
       where d.id = any(ids) and d.merge_log_id is not null and strpos(txt, d.merge_log_id::text) > 0;
      select count(*) into k from public.crm_steward_decisions d where d.id = any(ids) and d.merge_log_id is not null;
      reset role;
      -- PII scan: no person name, contact value or fixture marker of the owner's CRM appears in title, description or meta
      select count(*) into i from public.crm_people p
       where p.user_id = ub and length(btrim(p.display_name)) >= 4 and strpos(txt, lower(btrim(p.display_name))) > 0;
      select count(*) into dec0 from public.crm_contact_points cp join public.crm_people p on p.id = cp.person_id
       where p.user_id = ub and length(btrim(cp.value)) >= 5 and strpos(txt, lower(btrim(cp.value))) > 0;
      r := r || jsonb_build_object('TC-SB575-11', case
             when (res->'merges'->>'merged')::int = 3 and (a->>'sampled')::int = 10 and (a->>'merges')::int = 3
              and wi1 = wi0 + 1 and wi.id is not null and wi.ticket_code = a->>'ticket_code' and wi.ticket_code ~ '^SB-[0-9]+$'
              and wi.project_id = sb and wi.parent_id = epic and wi.type = 'task' and wi.status = 'todo'
              and wi.assignee = 'SupaBrain QA' and wi.assigned_agent_id is not null and wi.user_id = ub
              and wi.meta->>'originating_agent' = 'CRM Data Steward' and wi.meta->>'issue_type' = 'crm_steward_qa_sample'
              and wi.meta->>'run_id' = a->>'run_id' and jsonb_array_length(wi.meta->'decision_ids') = 10
              and (select array_agg(x::uuid) from jsonb_array_elements_text(wi.meta->'decision_ids') x) @> ids
              and wi.title ~ '^CRM Steward QA sample: week of \d{4}-\d{2}-\d{2} \(10 decisions, 3 merges\)$'
              and n = 10 and k = 3 and m = 3
              and i = 0 and dec0 = 0 and txt !~ '@' and txt !~ 'zarbock|quennell|ysmay|zq\.example'
             then 'pass' else format('FAIL: merged %s, sample %s, tickets %s->%s, ticket ok %s/%s/%s/%s/%s/%s, ids in text %s, undo handles %s of %s, names %s, contact values %s, at-sign %s',
                                     res->'merges'->'merged', a - 'run_id' - 'work_item', wi0, wi1, wi.project_id = sb, wi.parent_id = epic,
                                     wi.type, wi.status, wi.assignee, wi.meta->>'issue_type', n, m, k, i, dec0, txt ~ '@') end);
      r := r || jsonb_build_object('TC-SB575-11.evidence', format('ticket %s (rolled back): %s decisions, %s merges with undo handles; PII scan names %s, contact values %s',
                                     wi.ticket_code, a->'sampled', k, i, dec0));
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB575-11', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB575-12: weekly cron command is a no-op while automation is off
  begin
    begin
      select c.command into cmd from cron.job c where c.jobname = 'crm-steward-weekly';
      reset role;
      if (select automation_enabled from public.agents where id = aid) then raise exception 'precondition: automation is on'; end if;
      select count(*) into runs0 from public.agent_runs where agent_id = aid;
      select run_count into rc0 from public.agents where id = aid;
      select count(*) into wi0 from public.work_items where meta->>'issue_type' = 'crm_steward_qa_sample';
      select count(*) into dec0 from public.crm_steward_decisions where decision = 'qa_sample';
      execute cmd;
      cu := current_user; uid := auth.uid();
      reset role;
      select count(*) into runs1 from public.agent_runs where agent_id = aid;
      select run_count into rc1 from public.agents where id = aid;
      select count(*) into wi1 from public.work_items where meta->>'issue_type' = 'crm_steward_qa_sample';
      select count(*) into dec1 from public.crm_steward_decisions where decision = 'qa_sample';
      r := r || jsonb_build_object('TC-SB575-12', case
             when runs1 = runs0 and rc1 is not distinct from rc0 and wi1 = wi0 and dec1 = dec0
              and cu = 'authenticated' and uid = ub
             then 'pass' else format('FAIL: runs %s->%s run_count %s->%s tickets %s->%s samples %s->%s role %s',
                                     runs0, runs1, rc0, rc1, wi0, wi1, dec0, dec1, cu) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB575-12', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB575-13: weekly cron command with automation on: one completed weekly run as the owner
  begin
    begin
      select c.command into cmd from cron.job c where c.jobname = 'crm-steward-weekly';
      reset role;
      update public.agents set automation_enabled = true where id = aid and status = 'active';
      select count(*) into runs0 from public.agent_runs where agent_id = aid;
      select run_count into rc0 from public.agents where id = aid;
      select count(*) into wi0 from public.work_items where meta->>'issue_type' = 'crm_steward_qa_sample';
      execute cmd;
      cu := current_user; uid := auth.uid();
      reset role;
      select count(*) into runs1 from public.agent_runs where agent_id = aid;
      select run_count into rc1 from public.agents where id = aid;
      select count(*) into wi1 from public.work_items where meta->>'issue_type' = 'crm_steward_qa_sample';
      select * into ar from public.agent_runs where agent_id = aid order by created_at desc, started_at desc limit 1;
      -- the same job again this week: completed, sample skipped, no second ticket
      execute cmd;
      reset role;
      select count(*) into n from public.agent_runs where agent_id = aid;
      select count(*) into m from public.work_items where meta->>'issue_type' = 'crm_steward_qa_sample';
      select count(*) into k from public.agent_runs
       where agent_id = aid and status = 'completed' and run_metadata->>'task' = 'weekly'
         and (run_metadata#>>'{summary,qa_sample,skipped}')::boolean and result_summary like 'qa sample skipped%';
      r := r || jsonb_build_object('TC-SB575-13', case
             when cu = 'authenticated' and uid = ub and runs1 = runs0 + 1 and rc1 = coalesce(rc0, 0) + 1 and wi1 = wi0 + 1
              and ar.status = 'completed' and ar.trigger_type = 'scheduled' and ar.user_id = ub and ar.project_id = sb
              and ar.run_metadata->>'task' = 'weekly' and ar.run_metadata->>'source' = 'crm_steward_scheduled'
              and (ar.run_metadata#>>'{summary,qa_sample,sampled}')::int > 0
              and ar.result_summary ~ '^qa sample \d+ \(merges \d+\) SB-\d+; digest '
              and ar.duration_ms is not null and ar.error_message is null
              and n = runs1 + 1 and m = wi1 and k = 1
             then 'pass' else format('FAIL: role %s owner %s runs %s->%s->%s run_count %s->%s tickets %s->%s->%s status %s task %s dur %s summary_ok %s skipped_runs %s',
                                     cu, uid = ub, runs0, runs1, n, rc0, rc1, wi0, wi1, m, ar.status, ar.run_metadata->>'task', ar.duration_ms,
                                     ar.result_summary ~ '^qa sample \d+ \(merges \d+\) SB-\d+; digest ', k) end);
      r := r || jsonb_build_object('TC-SB575-13.evidence', format('run %s: %s, duration_ms %s, %s; second run skipped %s',
                                     ar.id, ar.status, ar.duration_ms, ar.result_summary, k));
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB575-13', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB575-14: posture, deployed bodies, constraint, index
  begin
    reset role;
    select count(*) into n from pg_proc p
     where p.oid in ('public.crm_steward_qa_sample(integer)'::regprocedure, 'public.crm_steward_record_verdict(uuid,text,text)'::regprocedure,
                     'public.crm_steward_scheduled(text)'::regprocedure)
       and not p.prosecdef and p.proconfig @> array['search_path=""']
       and not has_function_privilege('anon', p.oid, 'execute') and not has_function_privilege('public', p.oid, 'execute')
       and has_function_privilege('authenticated', p.oid, 'execute');
    select count(*) into m from pg_proc p
     where (p.oid = 'public.crm_steward_qa_sample(integer)'::regprocedure and md5(p.prosrc) = md5_sample)
        or (p.oid = 'public.crm_steward_record_verdict(uuid,text,text)'::regprocedure and md5(p.prosrc) = md5_verdict)
        or (p.oid = 'public.crm_steward_scheduled(text)'::regprocedure and md5(p.prosrc) = md5_scheduled and p.prosrc !~ 'duration_ms');
    select count(*) into k from pg_constraint
     where conname = 'crm_steward_decisions_decision_check' and pg_get_constraintdef(oid) ~ '''qa_sample''' and pg_get_constraintdef(oid) ~ '''qa_verdict''';
    select count(*) into i from pg_indexes where schemaname = 'public' and indexname = 'crm_steward_decisions_refers_to';
    r := r || jsonb_build_object('TC-SB575-14', case
           when n = 3 and m = 3 and k = 1 and i = 1 then 'pass'
           else format('FAIL: posture %s of 3, bodies %s of 3, constraint %s, index %s', n, m, k, i) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB575-14', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB575-15: the weekly cron job; cron calls only crm_steward_scheduled
  begin
    select count(*) into n from cron.job c
     where c.jobname = 'crm-steward-weekly' and c.active and c.schedule = '40 10 * * 1' and c.database = 'postgres'
       and c.command ~* '^\s*do\s' and c.command ~* 'set local role authenticated'
       and c.command ~ 'set_config\(''request\.jwt\.claims'''
       and c.command ~ 'crm_steward_scheduled\(''weekly''\)'
       and c.command ~ ('a\.id = ''' || aid::text || '''')
       and c.command !~* '\mname\M'
       and not exists (select 1 from auth.users u where position(u.id::text in lower(c.command)) > 0)
       and (select array_agg(distinct x[1]) from regexp_matches(lower(c.command),
              '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})', 'g') x) = array[aid::text];
    -- every crm_steward_* call in any cron command is crm_steward_scheduled
    select count(*) into m from cron.job c, regexp_matches(c.command, '(crm_steward_[a-z_]+)', 'g') x where x[1] <> 'crm_steward_scheduled';
    select count(*) into k from cron.job c where c.jobname in ('crm-steward-daily', 'crm-steward-weekly');
    r := r || jsonb_build_object('TC-SB575-15', case
           when n = 1 and m = 0 and k = 2 then 'pass'
           else format('FAIL: weekly job ok %s, other crm_steward_* calls in cron %s, steward jobs %s', n, m, k) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB575-15', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  reset role;
  if exists (select 1 from public.agents where id = aid and automation_enabled) then
    r := r || jsonb_build_object('GUARD', 'FAIL: automation_enabled left true inside the suite');
  end if;

  select count(*) into fails from jsonb_each_text(r) where key not like '%.evidence' and value <> 'pass';
  if fails = 0 then
    raise exception 'CRM-STEWARD-QA-SAMPLING PASS (% checks): %', (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  else
    raise exception 'CRM-STEWARD-QA-SAMPLING FAIL (% of % checks): %', fails,
      (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  end if;
end $suite$;
