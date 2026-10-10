
-- SB-376, second correction. Getting the STORE right was not enough.
--
-- With work_item_links as the source of truth, 8 of 21 completed Architect tickets still
-- flagged as gaps — and every one was self-contained: bugs the Architect fixed directly
-- (SB-370, SB-371, SB-385), a QA batch (SB-334), process changes (SB-395, SB-398),
-- engineering execution done in place (SB-061), a finding (SB-317). None produced a design
-- that someone else had to implement.
--
-- A handoff gap only means anything for work that PRODUCES a design requiring separate
-- implementation. Filtering on that is the difference between a detector and a nuisance:
-- an Architect who fixes a bug themselves has not dropped a handoff.
create or replace function public.detect_handoff_gaps(
  p_upstream_assignee text default 'System Architect',
  p_days int default 14,
  p_design_only boolean default true
)
returns table (
  ticket_code text,
  title text,
  ticket_type text,
  action_category text,
  completed_at timestamptz,
  has_link boolean,
  has_meta_key boolean,
  verdict text
)
language sql
stable
set search_path to 'public'
as $fn$
  select w.ticket_code, w.title, w.type, w.action_category, w.completed_at,
         exists (select 1 from work_item_links l
                  where l.from_item_id = w.id or l.to_item_id = w.id) as has_link,
         exists (select 1 from work_items d
                  where d.meta->>'upstream_ticket' = w.ticket_code) as has_meta_key,
         case
           when exists (select 1 from work_item_links l
                         where l.from_item_id = w.id or l.to_item_id = w.id)
             then 'linked — not a gap'
           when exists (select 1 from work_items d
                         where d.meta->>'upstream_ticket' = w.ticket_code)
             then 'linked via legacy meta key only — backfill work_item_links, not a gap'
           else 'NO DOWNSTREAM LINK — candidate gap, verify before escalating'
         end as verdict
    from work_items w
   where w.assignee = p_upstream_assignee
     and w.status = 'done'
     and not w.archived
     and w.completed_at > now() - make_interval(days => p_days)
     -- Only work that hands something off: a spike, or a design/approach decision.
     -- Bugs, QA batches, process changes and in-place execution hand off nothing.
     and (not p_design_only
          or w.type = 'spike'
          or w.action_category in ('architecture_change','technical_approach_selection','workflow_design','project_plan'))
   order by w.completed_at desc;
$fn$;

comment on function public.detect_handoff_gaps(text,int,boolean) is
  'SB-376: handoff-gap detection, corrected twice. Reads work_item_links (from_item_id/to_item_id), not the non-existent source_item_id/target_item_id and not the partial meta.upstream_ticket cache. p_design_only restricts to work that actually produces a design for someone else to implement — without it the detector flags every self-contained bug fix the Architect completed.';

grant execute on function public.detect_handoff_gaps(text,int,boolean) to authenticated, service_role;
;
