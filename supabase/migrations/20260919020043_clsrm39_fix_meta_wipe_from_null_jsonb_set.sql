-- CLSRM-39 part 4: fix a landmine part 2 put in the handoff.
--
-- Part 2 rewrote the reminder's meta with nested jsonb_set, one level of which
-- was:
--     jsonb_set(..., '{turned_in_reported_at}', to_jsonb(a.turned_in_reported_at))
--
-- to_jsonb(NULL::timestamptz) returns SQL NULL, not JSON null, and jsonb_set
-- returns NULL if ANY argument is NULL. So for every assignment with no
-- hand-in report -- which is all of them today -- the expression evaluated to
-- NULL and the UPDATE set work_items.meta = NULL, discarding the whole object.
--
-- That object carries qa_gate_exempt and review_gate_exempt. Losing them
-- reintroduces CLSRM-36 exactly: the next auto-resolve trips the review gate,
-- the exception aborts the school_assignments upsert, and the daily sweep
-- writes nothing again.
--
-- Not yet triggered in production: every exercise since part 2 was inside a
-- rolled-back probe, and the next real fire would have been the 15:15 sweep.
-- Found by reading an odd empty string in a probe's output rather than by any
-- assertion -- part 2 asserted the function body contained the right text, and
-- it did. The text was right and the value was NULL.
--
-- Fix: coalesce to JSON null so the key is written as null instead of
-- poisoning the whole expression.

do $$
declare def text; before_n int; after_n int;
begin
  select pg_get_functiondef('public.sync_school_assignment_to_fam(uuid)'::regprocedure) into def;

  select count(*) into before_n
    from regexp_matches(def, 'to_jsonb\(a\.turned_in_reported_at\)', 'g');
  if before_n = 0 then
    raise exception 'CLSRM-39: expected the unguarded to_jsonb call, found none';
  end if;

  def := replace(def,
    'to_jsonb(a.turned_in_reported_at)',
    'coalesce(to_jsonb(a.turned_in_reported_at), ''null''::jsonb)');

  execute def;

  select count(*) into after_n
    from regexp_matches(
      (select prosrc from pg_proc
        where oid='public.sync_school_assignment_to_fam(uuid)'::regprocedure),
      'coalesce\(to_jsonb\(a\.turned_in_reported_at\), ''null''::jsonb\)', 'g');
  if after_n <> before_n then
    raise exception 'CLSRM-39: guarded % of % to_jsonb calls', after_n, before_n;
  end if;
end $$;

-- Prove it on real rows, then roll the proof back.
do $$
declare a_id uuid; m jsonb; keys_before int; keys_after int;
begin
  select a.id into a_id from public.school_assignments a
   join public.work_items w on w.source_table='school_assignments' and w.source_id=a.id
   where not coalesce(a.archived,false) limit 1;
  if a_id is null then return; end if;

  select (select count(*) from jsonb_object_keys(coalesce(meta,'{}'::jsonb)))
    into keys_before from public.work_items
   where source_table='school_assignments' and source_id=a_id;

  -- an ordinary unreported touch: the case that would have wiped meta
  update public.school_assignments set updated_at = now() where id = a_id;

  select meta into m from public.work_items
   where source_table='school_assignments' and source_id=a_id;
  select count(*) into keys_after from jsonb_object_keys(coalesce(m,'{}'::jsonb));

  if m is null then
    raise exception 'CLSRM-39: meta is still wiped on an unreported touch';
  end if;
  if coalesce(m->>'review_gate_exempt','false') <> 'true' then
    raise exception 'CLSRM-39: review_gate_exempt lost on an unreported touch — CLSRM-36 would return';
  end if;
  if keys_after < keys_before then
    raise exception 'CLSRM-39: meta lost keys (% -> %)', keys_before, keys_after;
  end if;

  raise exception 'CLSRM-39 ROLLBACK OK: meta survived (% keys -> %), review_gate_exempt intact',
        keys_before, keys_after;
exception when others then
  if position('ROLLBACK OK' in SQLERRM) > 0 then
    raise notice '%', SQLERRM;   -- swallow the sentinel so the migration commits
  else
    raise;
  end if;
end $$;;
