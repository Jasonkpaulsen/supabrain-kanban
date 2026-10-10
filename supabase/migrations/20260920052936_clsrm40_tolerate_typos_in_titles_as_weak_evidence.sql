-- CLSRM-40 finding (3): survive the teacher's typo.
--
-- "worksheet" returned ZERO candidates because the assignment is titled
-- "Tips and Traits Worsheet" -- the teacher dropped the k. I first recorded this
-- as "not fixable in the resolver". That was wrong: it is not fixable by
-- SUBSTRING matching, which is a different claim. Edit distance handles it, and
-- no alias list ever could, because you cannot enumerate other people's
-- spelling mistakes in advance.
--
-- A third and deliberately WEAKER match tier: a query word within one or two
-- edits of a word in the title scores 2, below an exact title match (3).
--
-- Guards, because fuzzy matching is exactly how a resolver starts guessing:
--   * words of 5+ characters only -- short words collide far too easily
--   * compared against individual title WORDS, never the whole string
--   * distance 1 for 5-7 characters, 2 for 8 or more
--   * length difference capped at 2
--   * numbers are never fuzzy-matched: "HW 1" and "HW 2" are one edit apart
--     and are different assignments
--   * only reached when the exact tests already failed, so nothing double-counts
--
-- Safety measured rather than assumed: across every distinct title word of 5+
-- characters in the live corpus, ZERO pairs fall within these thresholds. The
-- rule introduces no new ambiguity in the data it will actually run against.
--
-- A lone fuzzy hit scores 2 and so cannot reach the confidence floor of 3 by
-- itself. That is intended. "worksheet" now SHOWS "Tips and Traits Worsheet"
-- instead of "nothing open matches", which is the whole problem -- but a
-- guessed spelling is not grounds to silently mark an assignment handed in.
-- Add any real word and it resolves: "tips and traits worksheet" -> 8, confident.
--
-- Measured, rolled back first. New behaviour:
--   worksheet                 -> 1 candidate (was 0), shown, refused at 2
--   tips and traits worksheet -> CONFIDENT at 8
--   micoscope                 -> finds "Microscope Diagram Label", refused at 2
-- Everything else in the 24-phrase corpus is unchanged, including the finding-2
-- refusal of "biology extension activity" and every existing confident match.
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
           -- base_score is the evidence, in three tiers: an exact word in the
           -- title (3), an exact word in the class name or a near-miss in the
           -- title (2), nothing (0). A number matches on digit boundaries, so
           -- '1' is not satisfied by "16th" or "9/10", and never fuzzily.
           ( select coalesce(sum(
               case when exists (select 1 from unnest(t.forms) f
                      where case when t.is_num
                                 then lower(a.title) ~ ('(^|[^0-9])'||f||'([^0-9]|$)')
                                 else position(f in lower(a.title)) > 0 end) then 3
                    when exists (select 1 from unnest(t.forms) f
                      where case when t.is_num
                                 then lower(a.class_name) ~ ('(^|[^0-9])'||f||'([^0-9]|$)')
                                 else position(f in lower(a.class_name)) > 0 end) then 2
                    -- Typo tolerance (CLSRM-40 finding 3). Long words only,
                    -- against whole title words, never numbers.
                    when (not t.is_num) and exists (
                           select 1 from unnest(t.forms) f
                           cross join lateral
                             unnest(regexp_split_to_array(lower(a.title), '[^a-z0-9]+')) tw
                            where length(f) >= 5 and length(tw) >= 5
                              and abs(length(f) - length(tw)) <= 2
                              and extensions.levenshtein(f, tw)
                                  <= (case when length(f) >= 8 then 2 else 1 end)
                         ) then 2
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
         -- that a rival was meant any less; neither is a guessed spelling.
         (    r.base_score = r.top_base
          and r.n_at_top = 1
          and r.base_score >= 3
          and r.base_score >= r.second_base + 3 ) as confident
    from ranked r
   where r.base_score > 0
   order by (r.base_score + r.exact_bonus) desc, r.due_date nulls last, r.title
   limit greatest(coalesce(p_limit, 10), 1);
$function$;
