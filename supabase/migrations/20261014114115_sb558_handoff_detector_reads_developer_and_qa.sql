-- SB-558 (ADR-FLOW-005 D9): the handoff-gap detector reads the developer and qa_status.
-- Approved by Jason 2026-10-06 (items 1-3). Item 4 was decided in SB-527 and is not changed here.
--
-- 1. The two old overloads are renamed and closed to client roles, so exactly one
--    detect_handoff_gaps exists and short calls no longer fail with 42725.
-- 2. classify_handoff_finding: one pure, first-match-wins classifier.
-- 3. detect_handoff_gaps: population by developer (meta.developed_by, else assignee) or assignee,
--    handoff link = blocks out / blocked_by in only, qa_status as evidence of shipped work.
-- No ticket data is rewritten.

alter function public.detect_handoff_gaps(text, integer) rename to detect_handoff_gaps_retired_sb558_v1;
alter function public.detect_handoff_gaps(text, integer, boolean) rename to detect_handoff_gaps_retired_sb558_v2;
revoke execute on function public.detect_handoff_gaps_retired_sb558_v1(text, integer) from public, anon, authenticated;
revoke execute on function public.detect_handoff_gaps_retired_sb558_v2(text, integer, boolean) from public, anon, authenticated;
comment on function public.detect_handoff_gaps_retired_sb558_v1(text, integer) is 'Retired by SB-558; to be removed in a later cleanup.';
comment on function public.detect_handoff_gaps_retired_sb558_v2(text, integer, boolean) is 'Retired by SB-558; to be removed in a later cleanup.';

create function public.classify_handoff_finding(
  p_developer text,
  p_upstream text,
  p_has_downstream boolean,
  p_has_meta_key boolean,
  p_qa_status text,
  p_is_design boolean)
returns text
language sql
immutable
set search_path = public
as $fn$
  select case
    when p_developer is distinct from p_upstream          then 'reviewed_only'
    when coalesce(p_has_downstream, false)                then 'linked'
    when coalesce(p_has_meta_key, false)                  then 'legacy_meta_backfill'
    when p_qa_status = 'tested' and coalesce(p_is_design, false) then 'design_complete'
    when p_qa_status = 'tested'                           then 'role_boundary'
    when p_qa_status = 'exempt'                           then 'shipped_exempt'
    when coalesce(p_is_design, false)                     then 'handoff_gap'
    else 'self_contained'
  end;
$fn$;

comment on function public.classify_handoff_finding(text, text, boolean, boolean, text, boolean) is
  'SB-558 / ADR-FLOW-005 D9: first match wins. reviewed_only, linked, legacy_meta_backfill, design_complete, role_boundary, shipped_exempt, handoff_gap, self_contained.';

create function public.detect_handoff_gaps(
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
           (w.type = 'spike'
            or w.action_category in ('architecture_change','technical_approach_selection','workflow_design','project_plan')) as design_work
      from work_items w
     where w.status = 'done'
       and not w.archived
       and w.completed_at >= now() - make_interval(days => p_days)
       and (coalesce(nullif(w.meta->>'developed_by', ''), w.assignee) = p_upstream_assignee
            or w.assignee = p_upstream_assignee)
  ), cls as (
    select p.*,
           public.classify_handoff_finding(p.developer, p_upstream_assignee, p.has_downstream_link,
                                           p.has_meta_key, p.qa_status, (not p_design_only) or p.design_work) as finding_type
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

revoke execute on function public.detect_handoff_gaps(text, integer, boolean) from public, anon;
grant execute on function public.detect_handoff_gaps(text, integer, boolean) to authenticated, service_role;
revoke execute on function public.classify_handoff_finding(text, text, boolean, boolean, text, boolean) from public, anon;
grant execute on function public.classify_handoff_finding(text, text, boolean, boolean, text, boolean) to authenticated, service_role;
comment on function public.detect_handoff_gaps(text, integer, boolean) is
  'Escalate only finding_type = handoff_gap; report role_boundary as a role-boundary finding, never as a handoff gap (SB-558).';

do $assert$
declare
  n int; bad int; m int;
begin
  select count(*) into n from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.proname = 'detect_handoff_gaps';
  if n <> 1 then raise exception 'SB-558 assert: % detect_handoff_gaps signatures, expected 1', n; end if;

  perform count(*) from public.detect_handoff_gaps('System Architect', 14);
  perform count(*) from public.detect_handoff_gaps();

  select count(*) into bad from public.detect_handoff_gaps('System Architect', 14, false) g
   where g.ticket_code in ('SB-453','SB-456','SB-458','SB-463','SB-464','SB-467','SB-469','SB-503','SB-540')
     and g.finding_type = 'handoff_gap';
  if bad <> 0 then raise exception 'SB-558 assert: % pinned SB-557 codes classified handoff_gap', bad; end if;

  select count(*) into m from (values
    ('Supabase Platform Engineer', 'System Architect', true,  true,  'tested',   true,  'reviewed_only'),
    ('System Architect',           'System Architect', true,  true,  'tested',   true,  'linked'),
    ('System Architect',           'System Architect', false, true,  'tested',   true,  'legacy_meta_backfill'),
    ('System Architect',           'System Architect', false, false, 'tested',   true,  'design_complete'),
    ('System Architect',           'System Architect', false, false, 'tested',   false, 'role_boundary'),
    ('System Architect',           'System Architect', false, false, 'exempt',   true,  'shipped_exempt'),
    ('System Architect',           'System Architect', false, false, 'untested', true,  'handoff_gap'),
    ('System Architect',           'System Architect', false, false, null,       false, 'self_contained')
  ) v(dev, up, dl, mk, qa, des, expected)
   where public.classify_handoff_finding(v.dev, v.up, v.dl, v.mk, v.qa, v.des) = v.expected;
  if m <> 8 then raise exception 'SB-558 assert: classify matrix % of 8', m; end if;

  if has_function_privilege('anon', 'public.detect_handoff_gaps(text,integer,boolean)', 'execute') then
    raise exception 'SB-558 assert: anon can execute detect_handoff_gaps';
  end if;
  if has_function_privilege('authenticated', 'public.detect_handoff_gaps_retired_sb558_v1(text,integer)', 'execute')
     or has_function_privilege('authenticated', 'public.detect_handoff_gaps_retired_sb558_v2(text,integer,boolean)', 'execute') then
    raise exception 'SB-558 assert: a retired overload is still executable by authenticated';
  end if;
end
$assert$;
