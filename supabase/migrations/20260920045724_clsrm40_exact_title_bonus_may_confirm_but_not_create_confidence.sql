-- CLSRM-40: an exact title match may CONFIRM a winner, not CREATE one.
--
-- Finding (2) of the TC-CLSRM-40-10 adversarial corpus (2026-09-20).
-- "biology extension activity" resolved CONFIDENTLY to "Biology Extension
-- Activity" (class: Academic Enrichment) at 19, beating "Extension Activity
-- Q 1" at 8 -- whose class is literally named "Biology 26-27 Per 6, 7 Even".
-- A parent saying that phrase could plausibly mean either. The +10 exact-title
-- bonus manufactured the separation the confidence rule then read as certainty.
--
-- That inverts this ticket's governing principle. A refusal costs one clarifying
-- question; a mis-resolution silently marks a real assignment as handed in and
-- removes it from the board, and nobody finds out until a grade does.
--
-- The rule is now stated where it can be checked: confidence is computed on the
-- BASE score -- the term matches alone. The exact-title bonus still orders the
-- results, so a typed-out title still appears first, but it can no longer lift a
-- candidate over a rival that the term matches did not already separate.
--
-- No inversion is possible between the two: if the query equals a title, every
-- query word is in that title, so that candidate already scores the maximum per
-- term. The bonus can only ever be decoration on a row that was already top.
--
-- Measured against the full 18-phrase corpus, rolled back first. Exactly one
-- verdict moves:
--   biology extension activity -> was confident, now REFUSES (9 vs 8 on base)
-- Everything else is unchanged, including every confident resolution that rests
-- on a genuine margin:
--   small is beautiful (6 vs 0), hw #1 (6 vs 3), homework #2 (6 vs 3),
--   homework 2 (6 vs 2), medical (3 vs 0), tips and traits (6 vs 0),
--   measuring (3 vs 0), friday do now (9 vs 6), geometry hw #7 (8 vs 5),
--   jai street sign project (9 vs 6)
-- and every refusal: geometry homework, hw 1, extension activity, do now,
--   english homework, me, the thing.
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
           -- base_score is the evidence: term matches only. A number matches on
           -- digit boundaries; a word matches as a substring. '1' must not be
           -- satisfied by "16th" or "9/10".
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
               from terms t ) as base_score,
           -- Ordering only. Deliberately kept out of the confidence test.
           case when lower(a.title) = lower(btrim(coalesce(p_query,''))) then 10 else 0 end
             as exact_bonus
      from public.school_assignments a
      join public.v_school_assignment_reconciliation r on r.id = a.id
     where not coalesce(a.archived, false)
       and (p_include_resolved or r.reconciliation_state <> 'agreed')
       and ((select child from inferred) is null
            or lower(a.child_name) = (select child from inferred))
  ),
  ranked as (
    select s.*,
           max(s.base_score) over ()                                        as top_base,
           (select coalesce(max(s2.base_score), 0) from scored s2
             where s2.base_score < (select max(s3.base_score) from scored s3)) as second_base,
           (select count(*) from scored s4
             where s4.base_score = (select max(s5.base_score) from scored s5)) as n_at_top
      from scored s
  )
  select r.id, r.child_name, r.class_name, r.title, r.due_date,
         r.classroom_status, r.reconciliation_state, r.turned_in_reported_at,
         (r.base_score + r.exact_bonus) as score,
         -- Confident only with genuine separation in the EVIDENCE: sole top,
         -- at least one title-strength match, and a full title-word clear of
         -- the runner-up. Typing a title verbatim is not, by itself, evidence
         -- that a rival was meant any less.
         (    r.base_score = r.top_base
          and r.n_at_top = 1
          and r.base_score >= 3
          and r.base_score >= r.second_base + 3 ) as confident
    from ranked r
   where r.base_score > 0
   order by (r.base_score + r.exact_bonus) desc, r.due_date nulls last, r.title
   limit greatest(coalesce(p_limit, 10), 1);
$function$;
