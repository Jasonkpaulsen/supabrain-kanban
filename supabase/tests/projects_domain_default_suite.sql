-- projects.domain default suite: TC-SB624-01, TC-SB624-02 (SB-624). TC-SB624-03 is
-- tests/unit/domain-taxonomy.test.ts.
--
-- Run as postgres. One transaction that always ends by raising, so the fixture projects it
-- inserts do not survive. Pass = the raised message starts with "PROJECTS_DOMAIN_DEFAULT PASS".
-- The message carries only counts, sqlstates and domain names.
--
-- TC-SB624-01: the column has no default and stays NOT NULL, so an insert that leaves domain
-- out fails with 23502 naming domain (it used to fail with 23514 on the stale default).
-- TC-SB624-02: every value the check allows (read from the live constraint) still inserts, and the column comment lists
-- exactly those values and says the value is required.

do $suite$
declare
  ub constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';   -- owner
  r jsonb := '{}'::jsonb;
  allowed text[]; d text; n int := 0; fails int; st text; col text; cmt text; missing text;
begin
  -- TC-SB624-01
  r := r || jsonb_build_object('TC-SB624-01.no_default',
         case when (select column_default is null and is_nullable = 'NO' from information_schema.columns
                     where table_schema = 'public' and table_name = 'projects' and column_name = 'domain')
              then 'pass' else 'FAIL: default present or nullable' end);
  begin
    insert into public.projects (name, user_id) values ('ZZ SB624 no-domain fixture', ub);
    r := r || jsonb_build_object('TC-SB624-01.omitted', 'FAIL: insert without domain succeeded');
  exception when others then
    get stacked diagnostics st = returned_sqlstate, col = column_name;
    r := r || jsonb_build_object('TC-SB624-01.omitted',
           case when st = '23502' and col = 'domain' then 'pass' else 'FAIL: ' || st || ' on ' || coalesce(col, '?') end);
  end;

  -- TC-SB624-02
  select array_agg(m[1] order by ord) into allowed
    from regexp_matches((select pg_get_constraintdef(oid) from pg_constraint
                          where conrelid = 'public.projects'::regclass and conname = 'projects_domain_check'),
                        '''([^'']+)''', 'g') with ordinality as x(m, ord);
  foreach d in array allowed loop
    begin
      insert into public.projects (name, user_id, domain) values ('ZZ SB624 ' || d || ' fixture', ub, d);
      n := n + 1;
    exception when others then
      r := r || jsonb_build_object('TC-SB624-02.insert_' || d, 'FAIL: ' || sqlstate);
    end;
  end loop;
  r := r || jsonb_build_object('TC-SB624-02.inserts',
         case when cardinality(allowed) >= 1 and n = cardinality(allowed) then 'pass' else 'FAIL: ' || n || ' of ' || cardinality(allowed) end);
  cmt := col_description('public.projects'::regclass,
           (select attnum from pg_attribute where attrelid = 'public.projects'::regclass and attname = 'domain'));
  select string_agg(a, ',') into missing from unnest(allowed) a where strpos(coalesce(cmt, ''), a) = 0;
  r := r || jsonb_build_object('TC-SB624-02.comment',
         case when missing is null and cmt ilike '%required%' and cmt not ilike '%professional%' then 'pass'
              else 'FAIL: comment missing ' || coalesce(missing, '-') end);

  select count(*) into fails from jsonb_each_text(r) where value <> 'pass';
  if fails = 0 then
    raise exception 'PROJECTS_DOMAIN_DEFAULT PASS (% checks): %', (select count(*) from jsonb_object_keys(r)), r::text;
  else
    raise exception 'PROJECTS_DOMAIN_DEFAULT FAIL (% of % checks): %', fails, (select count(*) from jsonb_object_keys(r)), r::text;
  end if;
end $suite$;
