-- SB-545 (found by TC-SB458-V2): a person with a contact cadence who has never
-- been contacted is due from the day they were added (ADR-CRM-002 §3). The
-- original view computed coalesce(last_contact_at, created_at) + cadence, so such
-- a person only became due a full cadence after being added, and was missing from
-- crm_review_stale_relationships meanwhile.
--
-- CREATE OR REPLACE with the same columns in the same order, so the dependent
-- view and the grants carry over unchanged.

create or replace view public.crm_contact_signals with (security_invoker = true) as
select s.*,
       concat_ws('; ',
         case when s.contact_cadence_days is not null then format('cadence %sd', s.contact_cadence_days) end,
         case when s.last_contact_at is null then 'no recorded contact'
              else format('last contact %s (%s, %s days ago)', s.last_contact_at::date, s.last_contact_type, s.days_since_contact) end,
         case when s.is_contact_overdue and s.last_contact_at is null then 'due since added'
              when s.is_contact_overdue then format('%s days past cadence', s.days_overdue) end,
         case when s.overdue_action_count > 0 then format('%s overdue action(s)', s.overdue_action_count) end,
         case when s.next_important_date <= current_date + 30
              then format('%s on %s', s.next_important_kind, s.next_important_date) end
       ) as explanation
from (
  select pe.id   as person_id,
         pe.user_id,
         pe.display_name,
         pe.relationship_priority,
         pe.contact_cadence_days,
         lc.occurred_at      as last_contact_at,
         lc.interaction_type as last_contact_type,
         current_date - lc.occurred_at::date as days_since_contact,
         due.next_contact_due_at,
         coalesce(due.next_contact_due_at <= now(), false) as is_contact_overdue,
         case when due.next_contact_due_at <= now()
              then greatest(0, current_date - due.next_contact_due_at::date) else 0 end as days_overdue,
         coalesce(ac.open_action_count, 0)    as open_action_count,
         coalesce(ac.overdue_action_count, 0) as overdue_action_count,
         ac.next_action_due_at,
         nd.next_date as next_important_date,
         nd.kind      as next_important_kind
    from public.crm_people pe
    -- latest interaction that has happened and is not archived
    left join lateral (
      select i.occurred_at, i.interaction_type
        from public.crm_interaction_participants ip
        join public.crm_interactions i on i.id = ip.interaction_id
       where ip.person_id = pe.id and not ip.archived and not i.archived and i.occurred_at <= now()
       order by i.occurred_at desc
       limit 1
    ) lc on true
    -- with a cadence: last contact + cadence; never contacted = due from the day added
    cross join lateral (
      select case when pe.contact_cadence_days is null then null
                  when lc.occurred_at is null then pe.created_at
                  else lc.occurred_at + make_interval(days => pe.contact_cadence_days)
             end as next_contact_due_at
    ) due
    left join lateral (
      select count(*) filter (where a.status = 'open')                     as open_action_count,
             count(*) filter (where a.status = 'open' and a.due_at < now()) as overdue_action_count,
             min(a.due_at) filter (where a.status = 'open')                 as next_action_due_at
        from public.crm_actions a
       where a.person_id = pe.id and not a.archived
    ) ac on true
    left join lateral (
      select d.kind, public.crm_next_occurrence(d.month, d.day, d.year, d.recurrence) as next_date
        from public.crm_important_dates d
       where d.person_id = pe.id and not d.archived
         and public.crm_next_occurrence(d.month, d.day, d.year, d.recurrence) is not null
       order by 2
       limit 1
    ) nd on true
   where not pe.archived
) s;

do $chk$
begin
  if pg_get_viewdef('public.crm_contact_signals'::regclass) not like '%WHEN (lc.occurred_at IS NULL) THEN pe.created_at%' then
    raise exception 'A1: never-contacted people are not due from the day added';
  end if;
  if not exists (select 1 from pg_class where oid = 'public.crm_contact_signals'::regclass
                  and reloptions @> array['security_invoker=true']) then
    raise exception 'A2: crm_contact_signals lost security_invoker';
  end if;
  if has_table_privilege('anon', 'public.crm_contact_signals', 'select')
     or not has_table_privilege('authenticated', 'public.crm_contact_signals', 'select') then
    raise exception 'A3: crm_contact_signals grants changed';
  end if;
end $chk$;;
