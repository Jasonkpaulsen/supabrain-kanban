-- SB-558 follow-up (ADR-FLOW-005 D9): the detector passes the real design flag to the classifier.
--
-- Defect in 20261014114115: detect_handoff_gaps passed is_design = (not p_design_only) or design_work
-- to classify_handoff_finding. In the full call that is true for every row, so role_boundary and
-- self_contained could never be returned, non-design work built and tested by the upstream role came
-- back as design_complete, and untested non-design work would have been classified handoff_gap.
-- Fix: the classifier gets design_work as is; (not p_design_only) stays only in the row filter.
-- Same signature, columns, grants and comment. No ticket data is rewritten.

create or replace function public.detect_handoff_gaps(
  p_upstream_assignee text default 'System Architect',
  p_days integer default 14,
  p_design_only boolean default true)
returns table(
  ticket_code text,
  title text,
  ticket_type text,
  action_category text,
  completed_at timestamptz,
  assignee text,
  developed_by text,
  qa_status text,
  has_downstream_link boolean,
  has_meta_key boolean,
  finding_type text,
  verdict text)
language sql
stable
set search_path = public
as $fn$
  with pop as (
    select w.id, w.ticket_code, w.title, w.type, w.action_category, w.completed_at, w.assignee, w.qa_status,
           coalesce(nullif(w.meta->>'developed_by', ''), w.assignee) as developer,
           exists (select 1 from work_item_links l
                    where (l.from_item_id = w.id and l.link_type = 'blocks')
                       or (l.to_item_id = w.id and l.link_type = 'blocked_by')) as has_downstream_link,
           (exists (select 1 from work_items d
                     where d.meta->>'upstream_ticket' = w.ticket_code)
            or coalesce(nullif(w.meta->>'downstream_ticket', ''), '') <> '') as has_meta_key,
           -- SB-376: only work that hands something off is design work.
           coalesce(w.type = 'spike'
            or w.action_category in ('architecture_change','technical_approach_selection','workflow_design','project_plan'),
            false) as design_work
      from work_items w
     where w.status = 'done'
       and not w.archived
       and w.completed_at >= now() - make_interval(days => p_days)
       and (coalesce(nullif(w.meta->>'developed_by', ''), w.assignee) = p_upstream_assignee
            or w.assignee = p_upstream_assignee)
  ), cls as (
    -- p_design_only only filters rows; the classifier always gets the row's own design flag.
    select p.*,
           public.classify_handoff_finding(p.developer, p_upstream_assignee, p.has_downstream_link,
                                           p.has_meta_key, p.qa_status, p.design_work) as finding_type
      from pop p
     where (not p_design_only) or p.design_work
  )
  select c.ticket_code, c.title, c.type, c.action_category, c.completed_at, c.assignee, c.developer, c.qa_status,
         c.has_downstream_link, c.has_meta_key, c.finding_type,
         case c.finding_type
           when 'reviewed_only'        then 'Built by another role; the upstream role only reviewed it. Not a handoff gap.'
           when 'linked'               then 'Has a blocks/blocked_by handoff link. Not a gap.'
           when 'legacy_meta_backfill' then 'Linked only through a legacy meta key; backfill work_item_links. Not a gap.'
           when 'design_complete'      then 'Design work built and tested by the upstream role. Informational; no handoff needed.'
           when 'role_boundary'        then 'Upstream role built and tested the work itself. Report as a role-boundary finding, not a handoff gap.'
           when 'shipped_exempt'       then 'Shipped with qa_status exempt. Informational.'
           when 'handoff_gap'          then 'Design work, untested, with no downstream link. Verify, then escalate as a handoff gap.'
           else                             'No handoff expected. Informational.'
         end as verdict
    from cls c
   order by c.completed_at desc;
$fn$;

do $assert$
declare
  n int; bad int; rb int; elig int; nd int; dflt int;
begin
  select count(*) into n from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.proname = 'detect_handoff_gaps';
  if n <> 1 then raise exception 'SB-558 fix assert: % detect_handoff_gaps signatures, expected 1', n; end if;

  if has_function_privilege('anon', 'public.detect_handoff_gaps(text,integer,boolean)', 'execute')
     or not has_function_privilege('authenticated', 'public.detect_handoff_gaps(text,integer,boolean)', 'execute') then
    raise exception 'SB-558 fix assert: detector grants changed';
  end if;
  if coalesce(obj_description('public.detect_handoff_gaps(text,integer,boolean)'::regprocedure, 'pg_proc'), '')
     not like 'Escalate only finding_type = handoff_gap;%' then
    raise exception 'SB-558 fix assert: detector comment changed';
  end if;

  -- End to end: every full-call row equals the classifier applied to the row's own design flag.
  select count(*) into bad from public.detect_handoff_gaps('System Architect', 14, false) g
   where g.finding_type is distinct from public.classify_handoff_finding(
           g.developed_by, 'System Architect', g.has_downstream_link, g.has_meta_key, g.qa_status,
           coalesce(g.ticket_type = 'spike'
             or g.action_category in ('architecture_change','technical_approach_selection','workflow_design','project_plan'), false));
  if bad <> 0 then raise exception 'SB-558 fix assert: % full-call rows disagree with the classifier', bad; end if;

  -- Non-design rows are never design_complete or handoff_gap.
  select count(*) into nd from public.detect_handoff_gaps('System Architect', 14, false) g
   where not coalesce(g.ticket_type = 'spike'
             or g.action_category in ('architecture_change','technical_approach_selection','workflow_design','project_plan'), false)
     and g.finding_type in ('design_complete', 'handoff_gap');
  if nd <> 0 then raise exception 'SB-558 fix assert: % non-design rows classified design_complete or handoff_gap', nd; end if;

  -- The verifier's four Architect-built, tested, unlinked non-design codes come back role_boundary.
  select count(*), count(*) filter (where g.finding_type = 'role_boundary') into elig, rb
    from public.detect_handoff_gaps('System Architect', 14, false) g
   where g.ticket_code in ('SB-561','SB-571','SB-583','CLSRM-53')
     and g.developed_by = 'System Architect' and g.qa_status = 'tested'
     and not g.has_downstream_link and not g.has_meta_key;
  if elig < 1 or rb <> elig then
    raise exception 'SB-558 fix assert: role_boundary % of % eligible pinned codes', rb, elig;
  end if;

  -- The default call returns design rows only, so never role_boundary or self_contained.
  select count(*) into dflt from public.detect_handoff_gaps() d
   where d.finding_type in ('role_boundary', 'self_contained');
  if dflt <> 0 then raise exception 'SB-558 fix assert: % default-call rows are role_boundary/self_contained', dflt; end if;
end
$assert$;
