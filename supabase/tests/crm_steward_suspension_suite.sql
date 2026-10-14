-- CRM steward suspension suite: TC-SB585-1..8, 10, 11 (SB-585; ADR-CRM-006 §4.2 "Suspension", §7).
-- TC-SB585-9 is the regression run of the steward, link-rule and schedule suites (recorded separately).
--
-- Auto-merge is suspended while the owner's newest suspend/resume decision is a suspend. Before
-- SB-585 "newest" was (created_at desc, id desc): rows written in one transaction share now() and
-- id is a random uuid, so a suspend and a resume written together were a coin flip. SB-585 orders by
-- crm_steward_decisions.seq (identity) through crm_steward_suspended(), which crm_steward_run calls.
--
-- Determinism is checked through the real steward path, not only the helper. Each iteration writes
-- the suspend/resume rows and a fresh fixture duplicate pair (same surname, shared email:
-- auto_merge_contact), runs crm_steward_run(false), reads merges.suspended and whether the pair was
-- merged, then rolls its own sub-block back.
--
-- Runs as postgres, acting as two signed-in users: ua (fixture tenant, no CRM data of its own; it
-- gets a fixture "CRM Data Steward" agent with automation on) and ub (the owner, read-only here apart
-- from rolled-back suspend rows and one dry run). One transaction that always ends by raising, so
-- nothing persists. Pass = the raised message starts with "CRM-STEWARD-SUSPENSION PASS".
-- Fixture names are invented; zq.example addresses mark fixture contacts. The message carries only
-- counts, booleans and sqlstates.

do $suite$
declare
  ua constant uuid := '5ebab8fc-e993-4aee-bbc1-eb8ff08a2e0e';   -- fixture tenant
  ub constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';   -- owner
  run_md5 constant text := '9d09d477dcdf5e71bfdcb96a8891c9ad';  -- SB-583 body with the one suspension line swapped (recomputed by QA)
  iters constant int := 40;
  rb constant text := '__sb585_rollback__';
  r jsonb := '{}'::jsonb;
  n int; m int; k int; i int; j int; len int; fails int; st text; msg text;
  ag uuid; pa uuid; pb uuid;
  s jsonb; h boolean; merged boolean; expect_susp boolean; last_dec text;
  flips int; helper_mismatch int; errs int; seq_before bigint;
  ub_base boolean; ua_v boolean; ub_v boolean; ub_run jsonb;
  st_a text; st_b text; st_c text; st_d text; st_e text; st_f text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
  set local role authenticated;
  if exists (select 1 from public.crm_steward_decisions) or exists (select 1 from public.crm_people) then
    raise exception 'CRM-STEWARD-SUSPENSION FAIL: fixture tenant is not empty';
  end if;
  insert into public.agents (user_id, name, system_prompt, automation_enabled)
    values (ua, 'CRM Data Steward', 'QA fixture steward agent (SB-585)', true) returning id into ag;

  -- ------------------------------------------------ TC-SB585-1: no suspend/resume rows -> not suspended
  begin
    begin
      h := public.crm_steward_suspended();
      insert into public.crm_people (display_name, family_name) values ('Peregrine Hollins', 'Hollins') returning id into pa;
      insert into public.crm_people (display_name, family_name) values ('Wenna Hollins', 'Hollins') returning id into pb;
      insert into public.crm_contact_points (person_id, kind, value) values (pa, 'email', 'sb585-0@zq.example'), (pb, 'email', 'sb585-0@zq.example');
      s := public.crm_steward_run(false);
      merged := exists (select 1 from public.crm_people a, public.crm_people b
                         where a.id = pa and b.id = pb and (a.merged_into_id = b.id or b.merged_into_id = a.id));
      r := r || jsonb_build_object('TC-SB585-1', case
             when h = false and not (s->'merges'->>'suspended')::boolean and merged
              and not exists (select 1 from public.crm_steward_decisions where decision in ('suspend', 'resume'))
             then 'pass' else format('FAIL: helper %s run %s merged %s', h, s->'merges', merged) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB585-1', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB585-2 / -3: suspend->resume and resume->suspend in one transaction
  foreach msg in array array['suspend,resume', 'resume,suspend'] loop
    flips := 0; helper_mismatch := 0; errs := 0;
    expect_susp := (msg = 'resume,suspend');
    for i in 1 .. iters loop
      begin
        if msg = 'suspend,resume' then
          insert into public.crm_steward_decisions (decision, rule, entity_type, reason_code) values ('suspend', 'qa_sb585', 'crm_steward_decisions', 'qa_suspend');
          insert into public.crm_steward_decisions (decision, rule, entity_type, reason_code) values ('resume', 'qa_sb585', 'crm_steward_decisions', 'qa_resume');
        else
          insert into public.crm_steward_decisions (decision, rule, entity_type, reason_code) values ('resume', 'qa_sb585', 'crm_steward_decisions', 'qa_resume');
          insert into public.crm_steward_decisions (decision, rule, entity_type, reason_code) values ('suspend', 'qa_sb585', 'crm_steward_decisions', 'qa_suspend');
        end if;
        insert into public.crm_people (display_name, family_name) values ('Peregrine Hollins', 'Hollins') returning id into pa;
        insert into public.crm_people (display_name, family_name) values ('Wenna Hollins', 'Hollins') returning id into pb;
        insert into public.crm_contact_points (person_id, kind, value)
          values (pa, 'email', format('sb585-%s@zq.example', i)), (pb, 'email', format('sb585-%s@zq.example', i));
        h := public.crm_steward_suspended();
        s := public.crm_steward_run(false);
        merged := exists (select 1 from public.crm_people a, public.crm_people b
                           where a.id = pa and b.id = pb and (a.merged_into_id = b.id or b.merged_into_id = a.id));
        if (s->'merges'->>'suspended')::boolean is distinct from expect_susp or merged = expect_susp then
          flips := flips + 1;
        end if;
        if h is distinct from (s->'merges'->>'suspended')::boolean then helper_mismatch := helper_mismatch + 1; end if;
        raise exception '%', rb;
      exception when others then
        if sqlerrm <> rb then errs := errs + 1; end if;
      end;
    end loop;
    r := r || jsonb_build_object(case when expect_susp then 'TC-SB585-3' else 'TC-SB585-2' end, case
           when flips = 0 and helper_mismatch = 0 and errs = 0 then 'pass'
           else format('FAIL: %s x%s: flips %s, helper/run mismatch %s, errors %s', msg, iters, flips, helper_mismatch, errs) end);
    r := r || jsonb_build_object(case when expect_susp then 'TC-SB585-3' else 'TC-SB585-2' end || '.evidence',
           format('%s x%s through crm_steward_run(false): flips %s, helper/run mismatch %s, errors %s', msg, iters, flips, helper_mismatch, errs));
  end loop;

  -- ------------------------------------------------ TC-SB585-4: random chains, the last row written wins
  perform setseed(0.585);
  flips := 0; errs := 0;
  for i in 1 .. iters loop
    begin
      len := 1 + floor(random() * 6)::int;
      for j in 1 .. len loop
        last_dec := case when random() < 0.5 then 'suspend' else 'resume' end;
        insert into public.crm_steward_decisions (decision, rule, entity_type, reason_code)
          values (last_dec, 'qa_sb585', 'crm_steward_decisions', 'qa_' || last_dec);
      end loop;
      s := public.crm_steward_run(true);
      if (s->'merges'->>'suspended')::boolean is distinct from (last_dec = 'suspend')
         or public.crm_steward_suspended() is distinct from (last_dec = 'suspend') then
        flips := flips + 1;
      end if;
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then errs := errs + 1; end if;
    end;
  end loop;
  r := r || jsonb_build_object('TC-SB585-4', case when flips = 0 and errs = 0 then 'pass'
         else format('FAIL: chains x%s: wrong %s, errors %s', iters, flips, errs) end);

  -- ------------------------------------------------ TC-SB585-5: callers cannot write seq
  begin
    begin
      -- (a) explicit seq on insert
      st_a := 'no error';
      begin
        insert into public.crm_steward_decisions (decision, rule, entity_type, reason_code, seq)
          values ('resume', 'qa_sb585', 'crm_steward_decisions', 'qa_resume', 1);
      exception when others then st_a := sqlstate; end;
      -- (b) update of seq by the owner role
      st_b := 'no error';
      begin
        update public.crm_steward_decisions set seq = 1 where true;
      exception when others then st_b := sqlstate; end;
      -- (c) OVERRIDING SYSTEM VALUE with a huge seq, then a legitimate suspend afterwards
      insert into public.crm_steward_decisions (decision, rule, entity_type, reason_code) values ('suspend', 'qa_sb585', 'crm_steward_decisions', 'qa_suspend');
      st_c := 'no error';
      begin
        insert into public.crm_steward_decisions (decision, rule, entity_type, reason_code, seq) overriding system value
          values ('resume', 'qa_sb585', 'crm_steward_decisions', 'qa_resume', 9223372036854775000);
      exception when others then st_c := sqlstate; end;
      insert into public.crm_steward_decisions (decision, rule, entity_type, reason_code) values ('suspend', 'qa_sb585', 'crm_steward_decisions', 'qa_suspend');
      h := public.crm_steward_suspended();
      s := public.crm_steward_run(true);
      -- After 20261009030308 (column-level INSERT without seq): (a) is refused either by the
      -- rewriter (428C9, GENERATED ALWAYS) or by the column privilege (42501); (c) must be 42501.
      r := r || jsonb_build_object('TC-SB585-5.evidence', format('explicit seq %s, update seq %s, OVERRIDING SYSTEM VALUE %s, helper after legit suspend %s', st_a, st_b, st_c, h));
      r := r || jsonb_build_object('TC-SB585-5', case
             when st_a in ('428C9', '42501') and st_b in ('42501', '428C9') and st_c = '42501'
              and h and (s->'merges'->>'suspended')::boolean
             then 'pass'
             else format('FAIL: explicit seq %s, update seq %s, OVERRIDING SYSTEM VALUE %s; newest legit row is suspend but helper=%s run.suspended=%s',
                         st_a, st_b, st_c, h, s->'merges'->'suspended') end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB585-5', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB585-6: still append-only
  begin
    begin
      insert into public.crm_steward_decisions (decision, rule, entity_type, reason_code) values ('suspend', 'qa_sb585', 'crm_steward_decisions', 'qa_suspend');
      st_a := 'no error'; begin update public.crm_steward_decisions set reason_code = 'qa_changed' where true; exception when others then st_a := sqlstate; end;
      st_b := 'no error'; begin delete from public.crm_steward_decisions where true; exception when others then st_b := sqlstate; end;
      reset role;
      st_c := 'no error'; begin update public.crm_steward_decisions set reason_code = 'qa_changed' where user_id = ua; exception when others then st_c := sqlstate; end;
      st_d := 'no error'; begin delete from public.crm_steward_decisions where user_id = ua; exception when others then st_d := sqlstate; end;
      st_e := 'no error'; begin update public.crm_steward_decisions set seq = seq where user_id = ua; exception when others then st_e := sqlstate; end;
      select count(*) into n from public.crm_steward_decisions where user_id = ua and reason_code = 'qa_suspend';
      r := r || jsonb_build_object('TC-SB585-6', case
             when st_a = '42501' and st_b = '42501' and st_c = '42501' and st_d = '42501' and st_e in ('42501', '428C9') and n = 1
             then 'pass' else format('FAIL: owner update %s delete %s; postgres update %s delete %s seq %s; rows %s', st_a, st_b, st_c, st_d, st_e, n) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB585-6', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB585-7: RLS isolates suspension per owner
  begin
    begin
      reset role;
      perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
      set local role authenticated;
      ub_base := public.crm_steward_suspended();
      -- ua suspends (newest row overall); ub must stay unaffected
      perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
      insert into public.crm_steward_decisions (decision, rule, entity_type, reason_code) values ('suspend', 'qa_sb585', 'crm_steward_decisions', 'qa_suspend');
      ua_v := public.crm_steward_suspended();
      perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
      ub_v := public.crm_steward_suspended();
      select count(*) into n from public.crm_steward_decisions where user_id = ua;   -- RLS: ub sees none of ua's rows
      ub_run := public.crm_steward_run(true, 5);                                      -- owner dry run, rolled back
      -- and the reverse: ub suspends, ua resumes, then ua must read not suspended and ub suspended
      insert into public.crm_steward_decisions (decision, rule, entity_type, reason_code) values ('suspend', 'qa_sb585', 'crm_steward_decisions', 'qa_suspend');
      perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
      insert into public.crm_steward_decisions (decision, rule, entity_type, reason_code) values ('resume', 'qa_sb585', 'crm_steward_decisions', 'qa_resume');
      k := (not public.crm_steward_suspended())::int;
      perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
      k := k + public.crm_steward_suspended()::int;
      -- as ub, a cross-tenant suspend row is refused by RLS
      st_f := 'no error';
      begin
        insert into public.crm_steward_decisions (user_id, actor_id, decision, rule, entity_type, reason_code)
          values (ua, ub, 'suspend', 'qa_sb585', 'crm_steward_decisions', 'qa_suspend');
      exception when others then st_f := sqlstate; end;
      r := r || jsonb_build_object('TC-SB585-7', case
             when ub_base = false and ua_v and ub_v = false and n = 0
              and not (ub_run->'merges'->>'suspended')::boolean and k = 2 and st_f = '42501'
             then 'pass' else format('FAIL: ub base %s, ua %s, ub %s, ub sees ua rows %s, ub run suspended %s, reverse ok %s of 2, cross insert %s',
                                     ub_base, ua_v, ub_v, n, ub_run->'merges'->'suspended', k, st_f) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB585-7', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB585-8: posture, deployed bodies, schema
  begin
    reset role;
    select count(*) into n from pg_proc p
     where p.oid = 'public.crm_steward_suspended()'::regprocedure
       and not p.prosecdef and p.proconfig @> array['search_path=""'] and p.provolatile = 's'
       and not has_function_privilege('anon', p.oid, 'execute') and not has_function_privilege('public', p.oid, 'execute')
       and has_function_privilege('authenticated', p.oid, 'execute') and p.prorettype = 'boolean'::regtype;
    select count(*) into m from pg_proc p
     where p.oid = 'public.crm_steward_run(boolean,integer)'::regprocedure
       and md5(p.prosrc) = run_md5
       and p.prosrc ~ 'v_suspended := public\.crm_steward_suspended\(\)'
       and p.prosrc !~ 'order by d\.created_at desc, d\.id desc'
       and not p.prosecdef and p.proconfig @> array['search_path=""']
       and not has_function_privilege('anon', p.oid, 'execute') and has_function_privilege('authenticated', p.oid, 'execute');
    select count(*) into k from information_schema.columns
     where table_schema = 'public' and table_name = 'crm_steward_decisions' and column_name = 'seq'
       and data_type = 'bigint' and is_identity = 'YES' and identity_generation = 'ALWAYS' and is_nullable = 'NO';
    select count(*) into i from pg_indexes where schemaname = 'public' and indexname = 'crm_steward_decisions_suspension';
    -- anon is refused at the privilege check
    st := 'no error';
    begin
      set local role anon;
      perform public.crm_steward_suspended();
    exception when others then st := sqlstate; end;
    reset role;
    -- no other function still reads suspension inline by created_at
    select count(*) into j from pg_proc p where p.pronamespace = 'public'::regnamespace
       and p.prosrc ~ 'crm_steward_decisions' and p.prosrc ~ 'created_at desc, d\.id desc';
    r := r || jsonb_build_object('TC-SB585-8', case
           when n = 1 and m = 1 and k = 1 and i = 1 and st = '42501' and j = 0 then 'pass'
           else format('FAIL: helper posture %s, run body/posture %s, seq identity %s, index %s, anon %s, inline readers %s', n, m, k, i, st, j) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB585-8', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB585-10: seq, id and created_at are server-authored
  -- 20261009030308: authenticated holds INSERT only on the 11 caller columns. Supplying id or
  -- created_at is refused (42501); ordinary inserts, with or without user_id/actor_id, still work.
  begin
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
      set local role authenticated;
      st_a := 'no error';
      begin
        insert into public.crm_steward_decisions (decision, rule, entity_type, reason_code, created_at)
          values ('suspend', 'qa_sb585', 'crm_steward_decisions', 'qa_suspend', now() + interval '1 year');
      exception when others then st_a := sqlstate; end;
      st_b := 'no error';
      begin
        insert into public.crm_steward_decisions (id, decision, rule, entity_type, reason_code)
          values (gen_random_uuid(), 'suspend', 'qa_sb585', 'crm_steward_decisions', 'qa_suspend');
      exception when others then st_b := sqlstate; end;
      st_c := 'no error';
      begin
        insert into public.crm_steward_decisions
          values (gen_random_uuid(), ua, ua, 'suspend', 'qa_sb585', 'crm_steward_decisions', null, 'qa_suspend');
      exception when others then st_c := sqlstate; end;
      seq_before := (select max(seq) from public.crm_steward_decisions);
      insert into public.crm_steward_decisions (decision, rule, entity_type, reason_code)
        values ('suspend', 'qa_sb585', 'crm_steward_decisions', 'qa_suspend');
      insert into public.crm_steward_decisions (user_id, actor_id, decision, rule, entity_type, reason_code)
        values (ua, ua, 'resume', 'qa_sb585', 'crm_steward_decisions', 'qa_resume');
      select count(*) into n from public.crm_steward_decisions
       where user_id = ua and actor_id = ua and rule = 'qa_sb585' and created_at = now()
         and seq > coalesce(seq_before, 0);
      h := public.crm_steward_suspended();
      reset role;
      -- privileges: exactly the 11 caller columns are insertable; nothing table-level; no anon
      select count(*) filter (where has_column_privilege('authenticated', 'public.crm_steward_decisions', a.attname, 'insert')),
             string_agg(a.attname, ',' order by a.attname) filter (where has_column_privilege('authenticated', 'public.crm_steward_decisions', a.attname, 'insert'))
        into m, msg
        from pg_attribute a where a.attrelid = 'public.crm_steward_decisions'::regclass and a.attnum > 0 and not a.attisdropped;
      select count(*) into k from pg_attribute a
       where a.attrelid = 'public.crm_steward_decisions'::regclass and a.attnum > 0 and not a.attisdropped
         and has_column_privilege('anon', 'public.crm_steward_decisions', a.attname, 'insert');
      r := r || jsonb_build_object('TC-SB585-10', case
             when st_a = '42501' and st_b = '42501' and st_c = '42501' and n = 2 and h = false
              and m = 11 and msg = 'actor_id,decision,entity_id,entity_type,merge_log_id,qa_verdict,reason_code,refers_to,rule,run_id,user_id'
              and k = 0
              and not has_table_privilege('authenticated', 'public.crm_steward_decisions', 'insert')
              and not has_table_privilege('authenticated', 'public.crm_steward_decisions', 'update')
              and not has_table_privilege('authenticated', 'public.crm_steward_decisions', 'delete')
              and not has_table_privilege('authenticated', 'public.crm_steward_decisions', 'truncate')
              and has_table_privilege('authenticated', 'public.crm_steward_decisions', 'select')
             then 'pass' else format('FAIL: created_at %s, id %s, no column list %s, legit rows %s, helper %s, insertable cols %s [%s], anon cols %s',
                                     st_a, st_b, st_c, n, h, m, msg, k) end);
      r := r || jsonb_build_object('TC-SB585-10.evidence', format('created_at %s, id %s, no column list %s, legit inserts %s of 2, insertable columns %s', st_a, st_b, st_c, n, m));
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB585-10', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB585-11: seq is unique, even for a privileged role
  begin
    begin
      reset role;
      insert into public.crm_steward_decisions (user_id, actor_id, decision, rule, entity_type, reason_code)
        values (ua, ua, 'suspend', 'qa_sb585', 'crm_steward_decisions', 'qa_suspend') returning seq into seq_before;
      st_a := 'no error';
      begin
        insert into public.crm_steward_decisions (user_id, actor_id, decision, rule, entity_type, reason_code, seq) overriding system value
          values (ua, ua, 'resume', 'qa_sb585', 'crm_steward_decisions', 'qa_resume', seq_before);
      exception when others then st_a := sqlstate; end;
      select count(*) into n from pg_index i
       where i.indrelid = 'public.crm_steward_decisions'::regclass and i.indisunique and i.indisvalid
         and i.indpred is null and i.indnatts = 1
         and i.indkey[0] = (select attnum from pg_attribute where attrelid = 'public.crm_steward_decisions'::regclass and attname = 'seq');
      r := r || jsonb_build_object('TC-SB585-11', case
             when st_a = '23505' and n = 1 then 'pass'
             else format('FAIL: duplicate seq as postgres %s, unique full index on seq %s', st_a, n) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB585-11', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  select count(*) into fails from jsonb_each_text(r) where key not like '%.evidence' and value <> 'pass';
  if fails = 0 then
    raise exception 'CRM-STEWARD-SUSPENSION PASS (% checks): %', (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  else
    raise exception 'CRM-STEWARD-SUSPENSION FAIL (% of % checks): %', fails,
      (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  end if;
end $suite$;
