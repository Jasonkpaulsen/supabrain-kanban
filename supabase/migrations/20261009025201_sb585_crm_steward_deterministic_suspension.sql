-- SB-585: the steward's suspension read was a coin flip when a suspend and a resume were written in
-- one transaction (both rows share now(), and the id tie-break is a random uuid). Decisions now carry
-- a monotonic identity `seq`, and suspension has one definition, crm_steward_suspended(), which
-- reads the owner's newest suspend/resume row by seq. crm_steward_run calls it; SB-575 and SB-574
-- will too. crm_steward_run is otherwise byte-identical to SB-583's (deployed md5 49ad0b2b...).

alter table public.crm_steward_decisions
  add column seq bigint generated always as identity;
comment on column public.crm_steward_decisions.seq is
  'SB-585. Monotonic insert order, including inserts within one transaction. Callers cannot set it.';
create index crm_steward_decisions_suspension
  on public.crm_steward_decisions (user_id, seq desc) where decision in ('suspend', 'resume');

create or replace function public.crm_steward_suspended()
returns boolean
language sql stable security invoker
set search_path = '' as $fn$
  select coalesce((select d.decision = 'suspend' from public.crm_steward_decisions d
                    where d.user_id = (select auth.uid()) and d.decision in ('suspend', 'resume')
                    order by d.seq desc limit 1), false);
$fn$;
comment on function public.crm_steward_suspended() is
  'SB-585 / ADR-CRM-006 §7. True while the owner''s newest suspend/resume decision is a suspend (by seq).';
revoke all on function public.crm_steward_suspended() from public, anon;
grant execute on function public.crm_steward_suspended() to authenticated, service_role;

-- crm_steward_run: swap the inline suspension read for the helper. The deployed body is SB-583's
-- (md5 49ad0b2b6c1da32d75d4483a2f275a7a); the patch refuses to run against anything else.
do $patch$
declare
  v_def text;
  v_old constant text := $o$  v_suspended := coalesce((select d.decision = 'suspend' from public.crm_steward_decisions d
                            where d.user_id = v_uid and d.decision in ('suspend', 'resume')
                            order by d.created_at desc, d.id desc limit 1), false);$o$;
  v_new constant text := '  v_suspended := public.crm_steward_suspended();  -- SB-585: deterministic (seq)';
begin
  if (select md5(prosrc) from pg_proc where oid = 'public.crm_steward_run(boolean,integer)'::regprocedure)
       <> '49ad0b2b6c1da32d75d4483a2f275a7a' then
    raise exception 'SB-585: crm_steward_run is not the SB-583 body; refusing to patch';
  end if;
  v_def := pg_get_functiondef('public.crm_steward_run(boolean,integer)'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'SB-585: expected exactly one inline suspension read in crm_steward_run';
  end if;
  execute replace(v_def, v_old, v_new);
end $patch$;

-- ---------------------------------------------------------------- assertions
do $chk$
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public'
                   and table_name = 'crm_steward_decisions' and column_name = 'seq' and is_identity = 'YES'
                   and identity_generation = 'ALWAYS') then
    raise exception 'A1: crm_steward_decisions.seq must be GENERATED ALWAYS AS IDENTITY';
  end if;
  if exists (select 1 from pg_proc where oid = 'public.crm_steward_suspended()'::regprocedure
              and (prosecdef or not proconfig @> array['search_path=""']))
     or has_function_privilege('anon', 'public.crm_steward_suspended()', 'execute') then
    raise exception 'A2: crm_steward_suspended must be SECURITY INVOKER, pinned, and closed to anon';
  end if;
  if (select prosrc from pg_proc where oid = 'public.crm_steward_run(boolean,integer)'::regprocedure)
       !~ 'crm_steward_suspended\(\)'
     or (select prosrc from pg_proc where oid = 'public.crm_steward_run(boolean,integer)'::regprocedure)
       ~ 'order by d\.created_at desc, d\.id desc' then
    raise exception 'A3: crm_steward_run must read suspension through crm_steward_suspended()';
  end if;
end $chk$;
