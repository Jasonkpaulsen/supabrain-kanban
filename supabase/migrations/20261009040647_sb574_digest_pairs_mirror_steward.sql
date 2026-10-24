-- SB-574 QA defect D1 (TC-SB574-3): the digest decided "would the steward merge this?" only for strong
-- pairs, but crm_steward_run applies the §4 rule to every candidate, and auto_merge_name_org (same
-- normalized name + shared organization) can merge a `possible` pair. Such a pair was listed as
-- gray_zone_shared_context and then merged. The pair loop now mirrors the steward exactly:
--   1. rule covers the pair, nothing restricted   -> the steward merges it: not for Jason;
--   2. rule covers the pair, restricted data      -> restricted_blocks_merge;
--   3. rule does not cover it: strong              -> strong_pair_not_merged;
--                              possible + context  -> gray_zone_shared_context.
-- (This also stops restricted_blocks_merge over-reporting strong pairs the rule would not merge.)
-- Patched in place between the "-- 2-4." and "-- 5." markers; refuses unless the deployed body is
-- SB-574's (md5 c5272b5c8a20fd8b2f4003207aec4bbe).

do $patch$
declare
  v_def   text;
  v_start int;
  v_end   int;
  v_new   constant text := $n$  -- 2-4. duplicate pairs the policy leaves to a person (mirrors crm_steward_run phase 2, SB-574 D1)
  for cand in select * from public.crm_duplicate_candidates(1000) loop
    select * into pa from public.crm_people where id = cand.person_a and user_id = v_uid and not archived;
    select * into pb from public.crm_people where id = cand.person_b and user_id = v_uid and not archived;
    continue when pa.id is null or pb.id is null;
    -- would the §4 rule (as amended by SB-583) merge it? (same test as the steward, any strength)
    names_ok := (pa.family_name is not null and pb.family_name is not null
                 and lower(btrim(pa.family_name)) = lower(btrim(pb.family_name)))
                or strpos(pa.name_normalized, pb.name_normalized) > 0
                or strpos(pb.name_normalized, pa.name_normalized) > 0;
    by_email := exists (select 1 from unnest(cand.reasons) x where x like 'same email %');
    by_phone := exists (select 1 from unnest(cand.reasons) x where x like 'same phone %')
                and public.crm_given_names_compatible(
                      public.crm_name_tokens(pa.given_name, pa.preferred_name, pa.display_name),
                      public.crm_name_tokens(pb.given_name, pb.preferred_name, pb.display_name));
    v_covered := (names_ok and (by_email or by_phone))
                 or (pa.name_normalized = pb.name_normalized
                     and exists (select 1 from public.crm_affiliations a1
                                   join public.crm_affiliations a2 on a2.organization_id = a1.organization_id
                                                                  and a2.person_id = pb.id and not a2.archived
                                  where a1.person_id = pa.id and not a1.archived));
    if v_covered then
      v_restr := exists (select 1 from public.crm_facts f where f.person_id in (pa.id, pb.id)
                           and f.sensitivity in ('sensitive', 'highly_sensitive') and not f.archived)
              or exists (select 1 from public.crm_actions x where x.person_id in (pa.id, pb.id)
                           and x.sensitivity in ('sensitive', 'highly_sensitive') and not x.archived)
              or exists (select 1 from public.crm_interaction_participants ip
                           join public.crm_interactions i on i.id = ip.interaction_id
                          where ip.person_id in (pa.id, pb.id) and not i.archived
                            and i.sensitivity in ('sensitive', 'highly_sensitive'));
      if v_restr then
        v_items := v_items || jsonb_build_object('type', 'restricted_blocks_merge',
                                                 'person_a', cand.person_a, 'person_b', cand.person_b);
      end if;
      continue;   -- otherwise the steward merges it (or the suspension item already stands)
    end if;

    if cand.strength = 'strong' then
      v_items := v_items || jsonb_build_object('type', 'strong_pair_not_merged',
        'person_a', cand.person_a, 'person_b', cand.person_b,
        'evidence', (select coalesce(jsonb_agg(distinct case when x like 'same email %' then 'same email'
                                                             when x like 'same phone %' then 'same phone'
                                                             when x like 'both at %' then 'same organization'
                                                             else 'other' end), '[]'::jsonb)
                       from unnest(cand.reasons) x));
      continue;
    end if;

    -- possible pair the rule does not cover: Jason's only if it shares context (else the run dismisses it)
    v_ctx := case
      when exists (select 1 from unnest(cand.reasons) x where x like 'both at %') then 'organization'
      when exists (select 1 from public.crm_group_members g1
                     join public.crm_group_members g2 on g2.group_id = g1.group_id
                                                     and g2.person_id = cand.person_b and not g2.archived
                    where g1.person_id = cand.person_a and not g1.archived) then 'group'
      when exists (select 1 from public.crm_person_relationships x
                    where not x.archived
                      and ((x.person_id = cand.person_a and x.related_person_id = cand.person_b)
                        or (x.person_id = cand.person_b and x.related_person_id = cand.person_a))) then 'relationship'
    end;
    if v_ctx is not null then
      v_items := v_items || jsonb_build_object('type', 'gray_zone_shared_context',
                                               'person_a', cand.person_a, 'person_b', cand.person_b, 'shares', v_ctx);
    end if;
  end loop;

$n$;
begin
  if (select md5(prosrc) from pg_proc where oid = 'public.crm_steward_digest(boolean)'::regprocedure)
       <> 'c5272b5c8a20fd8b2f4003207aec4bbe' then
    raise exception 'SB-574 fix: crm_steward_digest is not the SB-574 body; refusing to patch';
  end if;
  v_def := pg_get_functiondef('public.crm_steward_digest(boolean)'::regprocedure);
  v_start := position('  -- 2-4. duplicate pairs the policy leaves to a person' in v_def);
  v_end   := position('  -- 5. suspension of auto-merge' in v_def);
  if v_start = 0 or v_end = 0 or v_end < v_start then
    raise exception 'SB-574 fix: section markers not found in crm_steward_digest';
  end if;
  execute substr(v_def, 1, v_start - 1) || v_new || substr(v_def, v_end);
end $patch$;

do $chk$
begin
  if (select prosrc from pg_proc where oid = 'public.crm_steward_digest(boolean)'::regprocedure)
       !~ 'mirrors crm_steward_run phase 2, SB-574 D1' then
    raise exception 'A1: crm_steward_digest pair loop must mirror the steward';
  end if;
  if exists (select 1 from pg_proc where oid = 'public.crm_steward_digest(boolean)'::regprocedure
              and (prosecdef or not proconfig @> array['search_path=""']))
     or has_function_privilege('anon', 'public.crm_steward_digest(boolean)', 'execute') then
    raise exception 'A2: crm_steward_digest must stay SECURITY INVOKER, pinned, and closed to anon';
  end if;
end $chk$;
