
-- SB-376: the handoff-gap query, correct, in the database.
--
-- Enhancement B has now been reported wrong three times — SB-372, SB-374, SB-376 — and
-- twice "fixed" without the sweep skill changing, because the skill lives outside this
-- database and each fix corrected the data instead of the query. This puts the correct
-- logic somewhere the skill can CALL rather than re-derive, so the next sweep cannot get
-- the column names or the source of truth wrong again.
--
-- Two defects it corrects:
--   1. Step 3 queried work_item_links.source_item_id / target_item_id. Those columns do
--      not exist — the table uses from_item_id / to_item_id. As written, Step 3 errors.
--   2. Enhancement B read meta.upstream_ticket, a partial one-way cache maintained by
--      SB-372's trigger on NEW links only. work_item_links is the record.
create or replace function public.detect_handoff_gaps(
  p_upstream_assignee text default 'System Architect',
  p_days int default 14
)
returns table (
  ticket_code text,
  title text,
  completed_at timestamptz,
  has_link boolean,
  has_meta_key boolean,
  verdict text
)
language sql
stable
set search_path to 'public'
as $fn$
  select w.ticket_code,
         w.title,
         w.completed_at,
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
   order by w.completed_at desc;
$fn$;

comment on function public.detect_handoff_gaps(text,int) is
  'SB-376: correct handoff-gap detection. Reads work_item_links (from_item_id/to_item_id) as the source of truth, with meta.upstream_ticket reported only as a legacy fallback. Replaces the Management Agent Sweep Enhancement B / Step 3 logic, which used non-existent column names and the wrong store.';

grant execute on function public.detect_handoff_gaps(text,int) to authenticated, service_role;
;
