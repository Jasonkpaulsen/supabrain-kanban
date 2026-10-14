-- CLSRM-40: turn "Kai turned in the geometry homework" into exactly one
-- assignment, or refuse.
--
-- 46 live assignments, 15 classes, two children. Ambiguity is the normal case,
-- not the edge: Geometry HW #4 and HW #5 are both live and both missing.
-- A mis-resolved report records a false claim against an innocent assignment
-- AND quiets its reminder — CLSRM-26's unrecoverable direction, reached by
-- accident rather than by design. So: never guess.
--
-- Two functions on one ranking, so a list UI and an NL agent can never
-- disagree about what a phrase means:
--   find_school_assignments(...)                   -> candidates, never picks
--   report_school_assignment_turned_in_by_query()  -> records only on a single
--                                                     confident match, else
--                                                     raises WITH the candidates
--
-- Scoring is plain word overlap, weighted toward the title. No trigram, no
-- embedding: when this refuses, a parent has to understand why, and
-- "similarity 0.61" is not a reason anyone can act on.

create or replace function public.find_school_assignments(
  p_query            text,
  p_child            text    default null,
  p_include_resolved boolean default false,
  p_limit            integer default 10
)
returns table (
  id uuid, child_name text, class_name text, title text, due_date date,
  classroom_status text, reconciliation_state text,
  turned_in_reported_at timestamptz,
  score integer, confident boolean
)
language sql stable security invoker
set search_path to 'public', 'pg_temp'
as $$
  with words as (
    -- lowercase, split on non-letters/digits, drop noise that carries no signal
    select w from unnest(regexp_split_to_array(lower(coalesce(p_query,'')), '[^a-z0-9#]+')) as w
     where length(w) >= 2
       and w not in ('the','a','an','in','on','at','to','it','is','was','has','have',
                     'turned','turn','handed','hand','gave','give','did','done',
                     'assignment','homework','hw','work','his','her','my','for','and')
  ),
  -- a child named in the query wins over the parameter only when the parameter is absent
  inferred as (
    select coalesce(
             nullif(btrim(lower(coalesce(p_child,''))), ''),
             (select a.child_name from public.school_assignments a
               where lower(a.child_name) in (select w from words) limit 1)
           ) as child
  ),
  scored as (
    select a.id, a.child_name, a.class_name, a.title, a.due_date,
           a.status as classroom_status,
           r.reconciliation_state, a.turned_in_reported_at,
           ( select coalesce(sum(case when position(w in lower(a.title)) > 0 then 3
                                      when position(w in lower(a.class_name)) > 0 then 2
                                      else 0 end), 0)::int
               from words w_t(w) )
           + case when lower(a.title) = lower(btrim(coalesce(p_query,''))) then 10 else 0 end
             as score
      from public.school_assignments a
      join public.v_school_assignment_reconciliation r on r.id = a.id
     where not coalesce(a.archived, false)
       and (p_include_resolved or r.reconciliation_state <> 'agreed')
       and ((select child from inferred) is null
            or lower(a.child_name) = (select child from inferred))
  ),
  ranked as (
    select s.*, max(s.score) over () as top_score, count(*) filter (where s.score > 0) over () as n_hits
      from scored s
  )
  select r.id, r.child_name, r.class_name, r.title, r.due_date,
         r.classroom_status, r.reconciliation_state, r.turned_in_reported_at,
         r.score,
         -- confident = it scored, it is the outright top, and nothing ties it
         (r.score > 0 and r.score = r.top_score
          and (select count(*) from ranked r2 where r2.score = r.top_score) = 1) as confident
    from ranked r
   where r.score > 0
   order by r.score desc, r.due_date nulls last, r.title
   limit greatest(coalesce(p_limit, 10), 1);
$$;

comment on function public.find_school_assignments(text,text,boolean,integer) is
  'CLSRM-40: ranked candidates for a natural-language phrase. Returns them; never chooses. confident = scored, outright top, untied.';

create or replace function public.report_school_assignment_turned_in_by_query(
  p_query       text,
  p_reported_by text,
  p_child       text default null,
  p_method      text default 'physical',
  p_note        text default null
)
returns public.school_assignments
language plpgsql security invoker
set search_path to 'public', 'pg_temp'
as $$
declare
  hit  record;
  n    int;
  list text;
begin
  select count(*) into n
    from public.find_school_assignments(p_query, p_child, false, 10);

  if n = 0 then
    raise exception 'CLSRM-40: nothing open matches %. Try the class name, or check the child.',
      quote_literal(coalesce(p_query,''));
  end if;

  select * into hit
    from public.find_school_assignments(p_query, p_child, false, 10)
   where confident
   limit 1;

  if hit.id is null then
    select string_agg(format('  %s — %s: %s (due %s, %s)',
                             f.child_name, f.class_name, f.title,
                             coalesce(f.due_date::text,'no date'), f.classroom_status),
                      E'\n' order by f.score desc, f.title)
      into list
      from public.find_school_assignments(p_query, p_child, false, 5) f;
    raise exception E'CLSRM-40: % matches %, so nothing was recorded. Which one?\n%',
      n, quote_literal(coalesce(p_query,'')), list;
  end if;

  return public.report_assignment_turned_in(hit.id, p_reported_by, p_method, p_note);
end $$;

comment on function public.report_school_assignment_turned_in_by_query(text,text,text,text,text) is
  'CLSRM-40: the natural-language entry point. Records only on a single confident match; otherwise raises with the candidates so the caller can ask instead of guessing.';

revoke all on function public.find_school_assignments(text,text,boolean,integer) from public, anon;
revoke all on function public.report_school_assignment_turned_in_by_query(text,text,text,text,text) from public, anon;
grant execute on function public.find_school_assignments(text,text,boolean,integer) to authenticated, service_role;
grant execute on function public.report_school_assignment_turned_in_by_query(text,text,text,text,text) to authenticated, service_role;

do $$
begin
  if has_function_privilege('anon','public.find_school_assignments(text,text,boolean,integer)','execute')
     or has_function_privilege('anon','public.report_school_assignment_turned_in_by_query(text,text,text,text,text)','execute') then
    raise exception 'CLSRM-40: anon can reach a resolver function';
  end if;
  if (select prosecdef from pg_proc
      where oid='public.find_school_assignments(text,text,boolean,integer)'::regprocedure) then
    raise exception 'CLSRM-40: find_school_assignments must be SECURITY INVOKER';
  end if;
  if (select prosecdef from pg_proc
      where oid='public.report_school_assignment_turned_in_by_query(text,text,text,text,text)'::regprocedure) then
    raise exception 'CLSRM-40: the by-query reporter must be SECURITY INVOKER';
  end if;
end $$;;
