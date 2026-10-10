-- SB-471 (ADR-CRM-004 §4): explainable recommendations a person can dismiss.
--
-- crm_recommendations(max) lists, each with a plain reason and the ids it came from:
--   overdue_follow_up  open actions past due (restricted titles masked)
--   contact_gap        people past their contact cadence (the crm_contact_signals explanation)
--   upcoming_date      important dates in the next 14 days
--   possible_duplicate two live people sharing a normalized email, phone or handle
--   unconfirmed_fact   agent- or import-sourced facts nobody has confirmed (normal/private only)
--   no_contact_method  a cadence is set but no current contact point exists
-- It is STABLE (Postgres forbids it to write) and SECURITY INVOKER with an explicit
-- owner filter. It never returns a contact value or restricted content, and nothing
-- here sends, drafts or schedules anything.
--
-- A dismissal hides one subject_key. Keys carry the circumstance (the due date, the
-- occurrence date), so a rescheduled follow-up, a new contact gap or next year's
-- birthday is a new key and shows again. Archive a dismissal to undo it; `until`
-- snoozes it.

create table public.crm_recommendation_dismissals (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  kind        text not null check (kind in ('overdue_follow_up','contact_gap','upcoming_date',
                                            'possible_duplicate','unconfirmed_fact','no_contact_method')),
  subject_key text not null check (subject_key ~
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[0-9]{4}-[0-9]{2}-[0-9]{2}))?$'),
  reason_code text not null default 'not_useful' check (reason_code ~ '^[a-z0-9_]{3,64}$'),
  until       date,
  archived    boolean not null default false,
  archived_at timestamptz,
  meta        jsonb not null default '{}'::jsonb check (jsonb_typeof(meta) = 'object'),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
comment on table public.crm_recommendation_dismissals is
  'SB-471 / ADR-CRM-004. A recommendation the owner dismissed (optionally until a date). Archive the row to undo.';

create unique index crm_recommendation_dismissals_key
  on public.crm_recommendation_dismissals (user_id, kind, subject_key) where not archived;
create index crm_recommendation_dismissals_user on public.crm_recommendation_dismissals (user_id);

select public.crm_secure_owned_table('public.crm_recommendation_dismissals');

create function public.crm_dismiss_recommendation(
  p_kind        text,
  p_subject_key text,
  p_reason      text default 'not_useful',
  p_until       date default null
) returns uuid
language plpgsql security invoker set search_path = '' as $fn$
declare v_id uuid;
begin
  if p_kind is null or p_kind not in ('overdue_follow_up','contact_gap','upcoming_date',
                                      'possible_duplicate','unconfirmed_fact','no_contact_method') then
    raise exception 'unknown recommendation kind %', coalesce(p_kind, '(null)') using errcode = '22023';
  end if;
  insert into public.crm_recommendation_dismissals (kind, subject_key, reason_code, until)
  values (p_kind, p_subject_key, coalesce(p_reason, 'not_useful'), p_until)
  returning id into v_id;
  return v_id;
end $fn$;

revoke all on function public.crm_dismiss_recommendation(text, text, text, date) from public, anon;
grant execute on function public.crm_dismiss_recommendation(text, text, text, date) to authenticated, service_role;

create function public.crm_recommendations(p_max_results integer default 50)
returns table (kind text, subject_key text, person_id uuid, display_name text, title text,
               reason text, source_ids jsonb, rank integer)
language plpgsql stable security invoker
set search_path = '' as $fn$
declare
  v_uid uuid := auth.uid();
  lim   int := least(greatest(coalesce(p_max_results, 50), 1), 500);
begin
  if v_uid is null then
    return;
  end if;

  return query
  with
  overdue as (
    select 'overdue_follow_up'::text as k, 1 as kind_order,
           a.id::text || ':' || to_char(a.due_at at time zone 'UTC', 'YYYY-MM-DD') as key,
           a.person_id as pid, p.display_name as pname,
           'Follow up: ' || case when a.sensitivity in ('sensitive','highly_sensitive') then '(restricted)'
                                 else left(a.title, 120) end as ttl,
           format('follow-up %s was due %s (%s days ago)',
                  case when a.sensitivity in ('sensitive','highly_sensitive') then '(restricted)'
                       else '"' || left(a.title, 120) || '"' end,
                  to_char(a.due_at at time zone 'UTC', 'YYYY-MM-DD'),
                  greatest((current_date - (a.due_at at time zone 'UTC')::date), 0)) as why,
           jsonb_strip_nulls(jsonb_build_object('action_id', a.id, 'person_id', a.person_id,
                                                'organization_id', a.organization_id,
                                                'interaction_id', a.interaction_id)) as src,
           row_number() over (order by a.due_at,
                              array_position(array['urgent','high','normal','low'], a.priority)) as urgency
      from public.crm_actions a
      left join public.crm_people p on p.id = a.person_id
     where a.user_id = v_uid and not a.archived and a.status = 'open'
       and a.due_at is not null and a.due_at < now()
       and (a.person_id is null or not p.archived)
  ),
  gaps as (
    select 'contact_gap'::text, 2,
           s.person_id::text || ':' || to_char(s.next_contact_due_at at time zone 'UTC', 'YYYY-MM-DD'),
           s.person_id, s.display_name,
           'Get in touch with ' || s.display_name,
           s.explanation,
           jsonb_build_object('person_id', s.person_id),
           row_number() over (order by s.relationship_priority nulls last, s.days_overdue desc, s.display_name)
      from public.crm_contact_signals s
     where s.user_id = v_uid and s.is_contact_overdue
  ),
  dates as (
    select 'upcoming_date'::text, 3,
           d.date_id::text || ':' || to_char(d.next_date, 'YYYY-MM-DD'),
           d.person_id, d.display_name,
           d.display_name || ': ' || coalesce(d.label, d.kind),
           coalesce(d.label, d.kind)
             || case when d.days_until = 0 then ' is today' when d.days_until = 1 then ' is tomorrow'
                     else ' in ' || d.days_until || ' days' end
             || case when d.years is null then ''
                     when d.kind = 'birthday' then ' (turns ' || d.years || ')'
                     else ' (' || d.years || ' years)' end,
           jsonb_build_object('important_date_id', d.date_id, 'person_id', d.person_id),
           row_number() over (order by d.days_until, d.display_name)
      from public.crm_upcoming_dates(14) d
  ),
  shared as (
    select least(c1.person_id, c2.person_id) as a, greatest(c1.person_id, c2.person_id) as b,
           array_agg(distinct c1.kind order by c1.kind) as kinds
      from public.crm_contact_points c1
      join public.crm_contact_points c2
        on c2.user_id = c1.user_id and c2.kind = c1.kind
       and c2.value_normalized = c1.value_normalized and c2.person_id <> c1.person_id
     where c1.user_id = v_uid and c1.kind in ('email','phone','handle')
       and not c1.archived and not c2.archived
     group by 1, 2
  ),
  dups as (
    select 'possible_duplicate'::text, 4,
           sh.a::text || ':' || sh.b::text,
           sh.a, pa.display_name,
           'Possible duplicate: ' || pa.display_name || ' and ' || pb.display_name,
           'shares ' || array_to_string(array(select case k when 'email' then 'an email address'
                                                            when 'phone' then 'a phone number'
                                                            else 'a handle' end
                                                from unnest(sh.kinds) k), ' and ')
             || ' with ' || pb.display_name,
           jsonb_build_object('person_a', sh.a, 'person_b', sh.b),
           row_number() over (order by pa.display_name, pb.display_name)
      from shared sh
      join public.crm_people pa on pa.id = sh.a and not pa.archived
      join public.crm_people pb on pb.id = sh.b and not pb.archived
  ),
  facts as (
    select 'unconfirmed_fact'::text, 5,
           f.id::text,
           f.person_id, p.display_name,
           'Confirm or correct: ' || f.fact_type || ' for ' || p.display_name,
           format('%s-added fact "%s"%s is unconfirmed', f.source_type, f.fact_type,
                  case when f.confidence is null then '' else ' (confidence ' || f.confidence || ')' end),
           jsonb_build_object('fact_id', f.id, 'person_id', f.person_id),
           row_number() over (order by f.confidence nulls first, f.captured_at)
      from public.crm_facts f
      join public.crm_people p on p.id = f.person_id and not p.archived
     where f.user_id = v_uid and not f.archived and not f.is_confirmed
       and f.source_type in ('agent','import') and f.sensitivity in ('normal','private')
  ),
  unreachable as (
    select 'no_contact_method'::text, 6,
           p.id::text,
           p.id, p.display_name,
           'Add a way to reach ' || p.display_name,
           format('contact cadence %s days but no way to contact them is recorded', p.contact_cadence_days),
           jsonb_build_object('person_id', p.id),
           row_number() over (order by p.relationship_priority nulls last, p.display_name)
      from public.crm_people p
     where p.user_id = v_uid and not p.archived and p.contact_cadence_days is not null
       and not exists (select 1 from public.crm_contact_points c
                        where c.person_id = p.id and c.user_id = v_uid and c.is_current and not c.archived)
  ),
  all_recs as (
    select * from overdue
    union all select * from gaps
    union all select * from dates
    union all select * from dups
    union all select * from facts
    union all select * from unreachable
  ),
  visible as (
    select r.*
      from all_recs r
     where not exists (select 1 from public.crm_recommendation_dismissals d
                        where d.user_id = v_uid and d.kind = r.k and d.subject_key = r.key
                          and not d.archived and (d.until is null or d.until > current_date))
  )
  select v.k, v.key, v.pid, v.pname, v.ttl, v.why, v.src,
         (row_number() over (order by v.kind_order, v.urgency))::int
    from visible v
   order by v.kind_order, v.urgency
   limit lim;
end $fn$;

revoke all on function public.crm_recommendations(integer) from public, anon;
grant execute on function public.crm_recommendations(integer) to authenticated, service_role;

do $chk$
declare n int;
begin
  perform public.crm_assert_owned_table('public.crm_recommendation_dismissals');
  if (select provolatile from pg_proc where oid = 'public.crm_recommendations(integer)'::regprocedure) <> 's'
     or (select prosecdef from pg_proc where oid = 'public.crm_recommendations(integer)'::regprocedure) then
    raise exception 'A1: crm_recommendations must be STABLE and SECURITY INVOKER';
  end if;
  if has_function_privilege('anon', 'public.crm_recommendations(integer)', 'execute')
     or has_function_privilege('anon', 'public.crm_dismiss_recommendation(text,text,text,date)', 'execute') then
    raise exception 'A2: anon can call a recommendation function';
  end if;
  -- A3: nothing in the CRM can send: no crm_ function touches pg_net, no cron job runs CRM code
  select count(*) into n from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.proname like 'crm\_%' and p.prosrc ~* 'net\.http_';
  if n > 0 then raise exception 'A3: % crm_ function(s) reference net.http_*', n; end if;
  select count(*) into n from cron.job where command ~* 'crm_';
  if n > 0 then raise exception 'A3: % cron job(s) run CRM code', n; end if;
  -- A4: no contact values in the recommendation source
  if (select prosrc from pg_proc where oid = 'public.crm_recommendations(integer)'::regprocedure) ~ 'c[12]?\.value\M' then
    raise exception 'A4: crm_recommendations must not return contact values';
  end if;
end $chk$;
