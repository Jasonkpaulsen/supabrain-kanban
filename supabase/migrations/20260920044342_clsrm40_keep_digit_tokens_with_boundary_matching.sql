-- CLSRM-40: stop discarding the most discriminating word in the phrase.
--
-- Found by the TC-CLSRM-40-10 adversarial corpus (2026-09-20). The length >= 2
-- word filter silently dropped bare digits, so "hw 1" collapsed to "hw" and
-- returned an eight-way tie, while "hw #1" resolved confidently -- because "#1"
-- happens to be two characters. Nobody would predict that distinction.
-- "geometry homework 2" and "kai turned in hw 3 and hw 4" collapsed the same way.
--
-- Two changes, and the second is what makes the first safe:
--
--   1. A single digit now survives tokenisation.
--   2. A NUMERIC term matches on digit boundaries instead of as a substring.
--
-- Without (2), "hw 1" would be boosted by "September 16th", "9/10" and "1-1"
-- alike -- every date in every title -- which is noise, not evidence. With it,
-- '1' matches "HW #1", "HW 1:" and "Q 1", but not "16th" or "9/10".
-- Non-numeric terms keep substring matching, so "geometry" still matches
-- "Geometry Test 1-1" as before.
--
-- Measured against the full corpus, rolled back first:
--   homework 2 (jai)      -> now CONFIDENT "Homework #2" (6 vs 2); previously collapsed
--   hw 1                  -> still refuses, but on three real cross-class rivals at 6
--                            rather than an eight-way tie at 3 caused by the lost token
--   geometry hw 1         -> HW #1 sole top at 8 (was tied at 5)
--   geometry homework 2   -> HW #2 sole top at 8 (was tied at 5)
--   global hw 2           -> HW 2: Civilizations sole top at 8
--   hw #1, hw #7, geometry hw, geometry homework, homework #2, the thing,
--   small is beautiful, medical, friday do now, me, street sign -> unchanged
--
-- Nothing became confident that should not have. The confidence rule is
-- untouched: "geometry hw 1" and "geometry homework 2" now rank the right item
-- sole top but land a gap of 2, so they still refuse. That is the class-name
-- weight (2 vs 3 for a title), a separate question from this one, deliberately
-- not changed here.
CREATE OR REPLACE FUNCTION public.find_school_assignments(p_query text, p_child text DEFAULT NULL::text, p_include_resolved boolean DEFAULT false, p_limit integer DEFAULT 10)
 RETURNS TABLE(id uuid, child_name text, class_name text, title text, due_date date, classroom_status text, reconciliation_state text, turned_in_reported_at timestamp with time zone, score integer, confident boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with words as (
    -- Only true English filler. Domain nouns (homework, hw, project, test,
    -- packet, worksheet) are the discriminating tokens here and must survive,
    -- and so must a bare digit: "hw 1" means HW #1, not "some homework".
    select w from unnest(regexp_split_to_array(lower(coalesce(p_query,'')), '[^a-z0-9#]+')) as w
     where (length(w) >= 2 or w ~ '^[0-9]$')
       and w not in ('the','a','an','in','on','at','to','it','is','was','has','have',
                     'turned','turn','handed','hand','gave','give','did','done',
                     'his','her','my','for','and','that','this','one')
  ),
  terms as (
    -- One row per CONCEPT, carrying every spelling that counts for it, so a
    -- concept scores once however many of its spellings the query used.
    -- Extend by adding a group here, never by rewriting the user's word.
    select distinct on (grp) grp, forms, is_num from (
      select case when w in ('hw','homework') then 'hw' else w end as grp,
             case when w in ('hw','homework') then array['hw','homework']
                  else array[w] end as forms,
             (w ~ '^[0-9]+$') as is_num
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
           -- A number matches on digit boundaries; a word matches as a
           -- substring. '1' must not be satisfied by "16th" or "9/10".
           ( select coalesce(sum(
               case when exists (select 1 from unnest(t.forms) f
                      where case when t.is_num
                                 then lower(a.title) ~ ('(^|[^0-9])'||f||'([^0-9]|$)')
                                 else position(f in lower(a.title)) > 0 end) then 3
                    when exists (select 1 from unnest(t.forms) f
                      where case when t.is_num
                                 then lower(a.class_name) ~ ('(^|[^0-9])'||f||'([^0-9]|$)')
                                 else position(f in lower(a.class_name)) > 0 end) then 2
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
