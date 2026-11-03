-- CLSRM-40 part 2: the resolver confidently picked the wrong assignment.
--
-- Tested against live data, "geometry homework" for kai resolved — confidently —
-- to "Geometry Test 1-1: Wednesday, September 16th". A test, not homework.
-- Two independent mistakes combined:
--
-- 1. STOPLIST. I dropped 'homework', 'hw', 'assignment' and 'work' as noise.
--    In this corpus "HW" is the literal title prefix of every homework item, so
--    I removed the single most discriminating token in the domain. Generic
--    English stopwords are not domain stopwords.
--
-- 2. CONFIDENCE BAR. One matched word was enough. 'geometry' hit the title of
--    the test (weight 3) and only the class of the real homework (weight 2), so
--    a single incidental word outranked five better candidates and was declared
--    unambiguous.
--
-- Fix: keep the domain words, and require real separation — a unique top, a
-- floor of one title-strength match, and at least one full title-word of
-- daylight over the runner-up. On this corpus that makes "geometry homework"
-- a five-way tie, which refuses, while "geometry hw #5" still resolves.

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
    -- Only true English filler. Domain nouns (homework, hw, project, test,
    -- packet, worksheet) are the discriminating tokens here and must survive.
    select w from unnest(regexp_split_to_array(lower(coalesce(p_query,'')), '[^a-z0-9#]+')) as w
     where length(w) >= 2
       and w not in ('the','a','an','in','on','at','to','it','is','was','has','have',
                     'turned','turn','handed','hand','gave','give','did','done',
                     'his','her','my','for','and','that','this','one')
  ),
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
    select s.*,
           max(s.score) over ()                                        as top_score,
           (select coalesce(max(s2.score), 0) from scored s2
             where s2.score < (select max(s3.score) from scored s3))    as second_score,
           (select count(*) from scored s4
             where s4.score = (select max(s5.score) from scored s5))    as n_at_top
      from scored s
  )
  select r.id, r.child_name, r.class_name, r.title, r.due_date,
         r.classroom_status, r.reconciliation_state, r.turned_in_reported_at,
         r.score,
         -- Confident only with genuine separation: sole top, at least one
         -- title-strength match, and a full title-word clear of the runner-up.
         (    r.score = r.top_score
          and r.n_at_top = 1
          and r.score >= 3
          and r.score >= r.second_score + 3 ) as confident
    from ranked r
   where r.score > 0
   order by r.score desc, r.due_date nulls last, r.title
   limit greatest(coalesce(p_limit, 10), 1);
$$;

comment on function public.find_school_assignments(text,text,boolean,integer) is
  'CLSRM-40: ranked candidates for a natural-language phrase. Returns them; never chooses. confident = sole top, score >= 3, and >= 3 clear of the runner-up — one incidental word is never enough.';;
