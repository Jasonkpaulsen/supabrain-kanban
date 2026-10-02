-- CLSRM-40: "hw" and "homework" are the same word to a family.
--
-- Found executing TC-CLSRM-40-8 (2026-09-20). Titles read "HW #n"; nobody says
-- "aitch-double-you". Because the resolver matched surface spellings only,
-- "geometry homework" scored every HW item 2 (class-name match alone) while
-- "Geometry Test 1-1" scored 3 on its title -- making the TEST the sole top,
-- refused only by the >= 3 gap rule on a gap of ONE. Two points in either
-- direction and "geometry homework" would have confidently resolved to the
-- test: the exact defect this ticket was opened for. "geometry hw" meanwhile
-- produced a proper five-way tie at 5 and was never at risk.
--
-- The fix groups spellings rather than rewriting them. Rewriting "homework" to
-- "hw" would have been shorter and wrong: 'hw' is not a substring of
-- 'homework', so a title actually spelled "Homework #3" would have stopped
-- matching. A term is now a CONCEPT carrying every spelling that counts for it,
-- scored once -- so "geometry homework hw" cannot score the same idea twice.
--
-- Everything else is unchanged, including the confidence rule.
CREATE OR REPLACE FUNCTION public.find_school_assignments(p_query text, p_child text DEFAULT NULL::text, p_include_resolved boolean DEFAULT false, p_limit integer DEFAULT 10)
 RETURNS TABLE(id uuid, child_name text, class_name text, title text, due_date date, classroom_status text, reconciliation_state text, turned_in_reported_at timestamp with time zone, score integer, confident boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with words as (
    -- Only true English filler. Domain nouns (homework, hw, project, test,
    -- packet, worksheet) are the discriminating tokens here and must survive.
    select w from unnest(regexp_split_to_array(lower(coalesce(p_query,'')), '[^a-z0-9#]+')) as w
     where length(w) >= 2
       and w not in ('the','a','an','in','on','at','to','it','is','was','has','have',
                     'turned','turn','handed','hand','gave','give','did','done',
                     'his','her','my','for','and','that','this','one')
  ),
  terms as (
    -- One row per CONCEPT, carrying every spelling that counts for it, so a
    -- concept scores once however many of its spellings the query used.
    -- Extend by adding a group here, never by rewriting the user's word.
    select distinct on (grp) grp, forms from (
      select case when w in ('hw','homework') then 'hw' else w end as grp,
             case when w in ('hw','homework') then array['hw','homework']
                  else array[w] end as forms
        from words
    ) g
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
           ( select coalesce(sum(
               case when exists (select 1 from unnest(t.forms) f
                                  where position(f in lower(a.title)) > 0) then 3
                    when exists (select 1 from unnest(t.forms) f
                                  where position(f in lower(a.class_name)) > 0) then 2
                    else 0 end), 0)::int
               from terms t )
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
$function$;
