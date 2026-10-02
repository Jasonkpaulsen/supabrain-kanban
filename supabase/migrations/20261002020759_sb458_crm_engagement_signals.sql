-- SB-458: engagement signals and review queries. ADR-CRM-002 §2–§3.
--
-- Signals are derived in views from data the user entered: a contact cadence and
-- a relationship priority set by the user, interactions that happened, open
-- actions and important dates. There is deliberately no score column (SB-458:
-- opaque AI scores must not be canonical). Every flag is shown next to the inputs
-- that produced it and an `explanation` sentence built from those same inputs.
--
-- Everything here is security_invoker / SECURITY INVOKER: RLS on the base tables
-- decides what exists for the caller, and the views add no reach of their own.

alter table public.crm_people
  add column contact_cadence_days  integer  check (contact_cadence_days between 1 and 3650),
  add column relationship_priority smallint check (relationship_priority between 1 and 5);

comment on column public.crm_people.contact_cadence_days is
  'SB-458. User-set: be in touch at least every N days. Drives crm_contact_signals.next_contact_due_at.';
comment on column public.crm_people.relationship_priority is
  'SB-458. User-set: 1 = highest, 5 = lowest. Orders the review queues; never computed.';

-- ---------------------------------------------------------------- per-person signals
create view public.crm_contact_signals with (security_invoker = true) as
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
    -- with a cadence: last contact + cadence, or the date added if never contacted
    cross join lateral (
      select case when pe.contact_cadence_days is null then null
                  else coalesce(lc.occurred_at, pe.created_at) + make_interval(days => pe.contact_cadence_days)
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

-- ---------------------------------------------------------------- review: stale relationships
create view public.crm_review_stale_relationships with (security_invoker = true) as
select person_id, user_id, display_name, relationship_priority, contact_cadence_days,
       last_contact_at, last_contact_type, days_since_contact, next_contact_due_at, days_overdue,
       overdue_action_count, explanation
  from public.crm_contact_signals
 where is_contact_overdue
 order by relationship_priority asc nulls last, days_overdue desc, display_name;

-- ---------------------------------------------------------------- review: overdue actions
-- Titles of sensitive and highly_sensitive actions are masked, so this queue is
-- safe to hand to an agent (ADR-CRM-002 §3). The owner reads crm_actions directly.
create view public.crm_review_overdue_actions with (security_invoker = true) as
select a.id as action_id,
       a.user_id,
       case when a.sensitivity in ('normal','private') then a.title else '(restricted)' end as title,
       a.priority,
       a.due_at,
       greatest(0, current_date - a.due_at::date) as days_overdue,
       a.person_id,       p.display_name as person_name,
       a.organization_id, o.name         as organization_name,
       a.interaction_id,
       a.sensitivity,
       format('due %s, %s days overdue, priority %s',
              a.due_at::date, greatest(0, current_date - a.due_at::date), a.priority) as explanation
  from public.crm_actions a
  left join public.crm_people        p on p.id = a.person_id
  left join public.crm_organizations o on o.id = a.organization_id
 where a.status = 'open' and not a.archived and a.due_at < now()
 order by case a.priority when 'urgent' then 1 when 'high' then 2 when 'normal' then 3 else 4 end,
          a.due_at;

-- ---------------------------------------------------------------- review: upcoming dates
create function public.crm_upcoming_dates(
  p_within_days integer default 30,
  p_from        date    default current_date
) returns table (
  date_id uuid, person_id uuid, display_name text, kind text, label text,
  next_date date, days_until integer, years integer
)
language sql stable security invoker set search_path = '' as $fn$
  select d.id, d.person_id, p.display_name, d.kind, d.label,
         x.next_date,
         x.next_date - p_from,
         case when d.year is not null then extract(year from x.next_date)::int - d.year end
    from public.crm_important_dates d
    join public.crm_people p on p.id = d.person_id and not p.archived
   cross join lateral (
     select public.crm_next_occurrence(d.month, d.day, d.year, d.recurrence, p_from) as next_date
   ) x
   where not d.archived
     and x.next_date is not null
     and x.next_date <= p_from + least(greatest(coalesce(p_within_days, 30), 0), 366)
   order by x.next_date, p.display_name;
$fn$;

-- ---------------------------------------------------------------- grants
revoke all on public.crm_contact_signals, public.crm_review_stale_relationships,
              public.crm_review_overdue_actions from public, anon, authenticated;
grant select on public.crm_contact_signals, public.crm_review_stale_relationships,
                public.crm_review_overdue_actions to authenticated;
revoke all on function public.crm_upcoming_dates(integer, date) from public, anon;
grant execute on function public.crm_upcoming_dates(integer, date) to authenticated;

-- ---------------------------------------------------------------- assertions
do $chk$
declare v text;
begin
  perform public.crm_assert_owned_table('public.crm_people');
  foreach v in array array['crm_contact_signals','crm_review_stale_relationships','crm_review_overdue_actions'] loop
    if not exists (select 1 from pg_class where oid = ('public.' || v)::regclass
                    and reloptions @> array['security_invoker=true']) then
      raise exception 'A1: % is not security_invoker', v;
    end if;
    if has_table_privilege('anon', 'public.' || v, 'select') then
      raise exception 'A2: anon can read %', v;
    end if;
  end loop;
  if (select prosecdef from pg_proc where oid = 'public.crm_upcoming_dates(integer,date)'::regprocedure) then
    raise exception 'A3: crm_upcoming_dates must be SECURITY INVOKER';
  end if;
  -- SB-458: no opaque score is canonical.
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name like 'crm\_%' and column_name ~ 'score') then
    raise exception 'A4: a CRM table or view carries a score column';
  end if;
end $chk$;;
