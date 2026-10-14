-- OAuth client default-deny suite: TC-SB595-1..6 (SB-595; ADR-API-002, SB-409).
--
-- Run as postgres. One transaction that always ends by raising, so nothing it creates or
-- inserts survives. Probes act as Mandy's OAuth session (her uid plus the registered client_id
-- of her active connection), as her direct session (no client_id) and as the owner.
-- Pass = the raised message starts with "OAUTH-DEFAULT-DENY PASS". The message carries only
-- counts, booleans and sqlstates, never row content.

do $suite$
declare
  ub    constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';   -- owner
  mandy constant uuid := '0dd94a9f-1890-48b0-9e4f-a4bbfff949f0';   -- principal of the family connection
  rb    constant text := '__sb595_rollback__';
  r jsonb := '{}'::jsonb;
  cid text; t text; n int; m int; k int; fails int; st text; msg text;
  formerly constant text[] := array['crm_people','crm_contact_points','crm_interactions','crm_facts','crm_organizations',
                                    'crm_steward_decisions','crm_audit_log','crm_merge_log','school_courses',
                                    'external_connection_limits','external_connection_audit_log'];
begin
  select oauth_client_id into cid from public.external_connections where principal_user_id = mandy and status = 'active' limit 1;
  if cid is null then raise exception 'OAUTH-DEFAULT-DENY FAIL: no active connection for the principal'; end if;

  -- ------------------------------------------------ TC-SB595-1: coverage, recomputed from the catalog
  begin
    select count(*) into n from pg_class c join pg_namespace s on s.oid = c.relnamespace
     where s.nspname = 'public' and c.relkind in ('r', 'p')
       and not exists (select 1 from pg_policy p where p.polrelid = c.oid and p.polname like 'oauth_client%');
    select count(*) into m from public.vw_oauth_client_coverage_gaps;
    r := r || jsonb_build_object('TC-SB595-1', case when n = 0 and m = 0 then 'pass'
           else format('FAIL: uncovered tables %s, view rows %s', n, m) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB595-1', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB595-2: the OAuth client cannot write or read them
  begin
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', mandy, 'role', 'authenticated', 'client_id', cid)::text, true);
      set local role authenticated;
      msg := ''; k := 0;
      foreach t in array formerly loop
        begin execute format('select count(*) from public.%I', t) into n; exception when others then n := -1; end;
        if n <> 0 then msg := msg || format('[read %s=%s] ', t, n); end if;
      end loop;
      st := 'ok'; begin insert into public.crm_people (display_name) values ('qa-sb595 probe'); exception when others then st := sqlstate; end;
      if st = '42501' then k := k + 1; else msg := msg || '[crm_people insert ' || st || '] '; end if;
      st := 'ok'; begin insert into public.crm_contact_points (person_id, kind, value) values (gen_random_uuid(), 'email', 'qa-sb595@zq.example'); exception when others then st := sqlstate; end;
      if st = '42501' then k := k + 1; else msg := msg || '[crm_contact_points insert ' || st || '] '; end if;
      st := 'ok'; begin insert into public.school_courses (user_id) values (mandy); exception when others then st := sqlstate; end;
      if st = '42501' then k := k + 1; else msg := msg || '[school_courses insert ' || st || '] '; end if;
      reset role;
      r := r || jsonb_build_object('TC-SB595-2', case when msg = '' and k = 3 then 'pass' else 'FAIL: ' || msg end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB595-2', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB595-3: direct sessions are unchanged
  begin
    begin
      reset role;
      select count(*) into m from public.crm_people where user_id = ub;
      perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
      set local role authenticated;
      select count(*) into n from public.crm_people;
      reset role;
      perform set_config('request.jwt.claims', json_build_object('sub', mandy, 'role', 'authenticated')::text, true);
      set local role authenticated;
      st := 'ok'; begin insert into public.crm_people (display_name) values ('qa-sb595 direct probe'); exception when others then st := sqlstate; end;
      reset role;
      r := r || jsonb_build_object('TC-SB595-3', case when n = m and m > 0 and st = 'ok' then 'pass'
             else format('FAIL: owner sees %s of %s; principal direct insert %s', n, m, st) end);
      r := r || jsonb_build_object('TC-SB595-3.evidence', format('owner direct session reads %s of %s owner rows; principal direct insert %s', n, m, st));
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB595-3', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB595-4: a new public table gets the deny automatically
  begin
    begin
      reset role;
      execute 'create table public.qa_sb595_t1 (id int primary key)';
      execute 'create table public.qa_sb595_t2 as select 1 as id';
      execute 'create schema qa_sb595_other';
      execute 'create table qa_sb595_other.t3 (id int)';
      select count(*) into n from pg_policy where polrelid = 'public.qa_sb595_t1'::regclass and polname = 'oauth_client_deny' and not polpermissive;
      select count(*) into m from pg_policy where polrelid = 'public.qa_sb595_t2'::regclass and polname = 'oauth_client_deny' and not polpermissive;
      select count(*) into k from pg_policy where polrelid = 'qa_sb595_other.t3'::regclass;
      r := r || jsonb_build_object('TC-SB595-4', case when n = 1 and m = 1 and k = 0 then 'pass'
             else format('FAIL: create table %s, create table as %s, other schema %s', n, m, k) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB595-4', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB595-5: granted resources untouched
  begin
    begin
      reset role;
      select count(*) into n from (select polrelid from pg_policy
        where polname in ('oauth_client_select','oauth_client_insert','oauth_client_update','oauth_client_delete')
        group by polrelid having count(*) = 4) x;
      select count(*) into m from pg_trigger where tgname = 'trg_oauth_client_immutable' and not tgisinternal;
      select count(*) into k from (select polrelid from pg_policy
        where polname in ('oauth_client_deny_insert','oauth_client_deny_update','oauth_client_deny_delete')
        group by polrelid having count(*) = 3) x;
      perform set_config('request.jwt.claims', json_build_object('sub', mandy, 'role', 'authenticated', 'client_id', cid)::text, true);
      set local role authenticated;
      execute 'select count(*) from public.work_items' into st;
      reset role;
      r := r || jsonb_build_object('TC-SB595-5', case when n = 16 and m = 15 and k = 3 and st::int > 0 then 'pass'
             else format('FAIL: four-policy tables %s, immutable triggers %s, write-denied registry %s, oauth work_items %s', n, m, k, st) end);
      r := r || jsonb_build_object('TC-SB595-5.evidence', format('four-policy %s, triggers %s, registry %s, OAuth session work_items %s', n, m, k, st));
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB595-5', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB595-6: posture
  begin
    select count(*) into n from pg_proc p
     where p.oid = 'public.oauth_client_default_deny()'::regprocedure
       and not p.prosecdef and p.proconfig @> array['search_path=""']
       and not has_function_privilege('anon', p.oid, 'execute')
       and not has_function_privilege('authenticated', p.oid, 'execute');
    select count(*) into m from pg_event_trigger e
     where e.evtname = 'oauth_client_default_deny' and e.evtenabled = 'O' and e.evtevent = 'ddl_command_end'
       and e.evttags @> array['CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO'] and cardinality(e.evttags) = 3;
    select count(*) into k from pg_class c
     where c.oid = 'public.vw_oauth_client_coverage_gaps'::regclass
       and c.reloptions @> array['security_invoker=true']
       and not has_table_privilege('anon', c.oid, 'select');
    r := r || jsonb_build_object('TC-SB595-6', case when n = 1 and m = 1 and k = 1 then 'pass'
           else format('FAIL: function %s, event trigger %s, view %s', n, m, k) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB595-6', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  reset role;
  select count(*) into fails from jsonb_each_text(r) where key not like '%.evidence' and value <> 'pass';
  if fails = 0 then
    raise exception 'OAUTH-DEFAULT-DENY PASS (% checks): %', (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  else
    raise exception 'OAUTH-DEFAULT-DENY FAIL (% of % checks): %', fails,
      (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  end if;
end $suite$;
