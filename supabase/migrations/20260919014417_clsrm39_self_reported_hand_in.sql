-- CLSRM-39: record a child's self-reported hand-in as a fact in its own right,
-- separate from what Google Classroom says.
--
-- Many assignments are handed in physically. Classroom will never say
-- 'submitted' for those, so the FAM board nags about work that is already done.
--
-- These are two independent observations of the same event, from sources with
-- different reliability and different latency. Collapsing them into one column
-- would destroy the ability to see them disagree -- and the disagreement is the
-- point: "reported turned in nine days ago, teacher still has it as missing" is
-- the sentence a parent needs, and no single-column design can produce it.
--
-- A self-report therefore changes how an item is PRESENTED, never whether it
-- exists. CLSRM-26 recorded why: "nagging about work already done is fixable in
-- a sentence; silently telling a parent there is nothing to do when three items
-- are overdue is not." A child's self-report is the input most likely to be
-- optimistic or mistaken, so it must not be in charge of the safety mechanism.
-- An uncorroborated report gets louder with age rather than quieter.
--
-- Survival across the daily scrape is by construction, not by luck:
-- assignment_to_row() returns an explicit dict of Google-owned fields; the DSN
-- path's ON CONFLICT DO UPDATE SET names its columns one at a time; PostgREST's
-- resolution=merge-duplicates only sets columns present in the request body.
-- No path can reach these columns unless someone adds them to the row builder.

alter table public.school_assignments
  add column if not exists turned_in_reported_at timestamptz,
  add column if not exists turned_in_reported_by text,
  add column if not exists turned_in_method      text,
  add column if not exists turned_in_note        text;

comment on column public.school_assignments.turned_in_reported_at is
  'CLSRM-39: when a child (or a parent relaying) reported handing this in outside Classroom. Never written by the scraper.';
comment on column public.school_assignments.turned_in_reported_by is
  'CLSRM-39: who reported it. Required whenever turned_in_reported_at is set — an anonymous claim is not evidence.';
comment on column public.school_assignments.turned_in_method is
  'CLSRM-39: physical | in_person | email | other. Non-Classroom hand-in is the reason this column set exists.';

do $$
begin
  if not exists (select 1 from pg_constraint
                 where conrelid='public.school_assignments'::regclass
                   and conname='school_assignments_turned_in_report_is_attributed') then
    alter table public.school_assignments
      add constraint school_assignments_turned_in_report_is_attributed
      check (turned_in_reported_at is null or turned_in_reported_by is not null);
  end if;

  if not exists (select 1 from pg_constraint
                 where conrelid='public.school_assignments'::regclass
                   and conname='school_assignments_turned_in_method_check') then
    alter table public.school_assignments
      add constraint school_assignments_turned_in_method_check
      check (turned_in_method is null
             or turned_in_method in ('physical','in_person','email','other'));
  end if;
end $$;

create index if not exists school_assignments_turned_in_reported_idx
  on public.school_assignments (child_project_id, turned_in_reported_at)
  where turned_in_reported_at is not null and archived = false;

-- One place to tune the marking-lag tolerance. Seven days: long enough for an
-- ordinary teacher lag, short enough that lost work surfaces inside the school week.
create or replace function public.turned_in_grace_days()
returns integer language sql immutable
set search_path to 'pg_catalog'
as $$ select 7 $$;

comment on function public.turned_in_grace_days() is
  'CLSRM-39: days a self-reported hand-in is allowed to go unrecorded by the teacher before the FAM reminder escalates from medium back to high.';

-- Derived, never stored: nothing to keep in sync, and it cannot go stale.
create or replace view public.v_school_assignment_reconciliation
with (security_invoker = true) as
select a.id,
       a.child_name,
       a.class_name,
       a.title,
       a.due_date,
       a.status                as classroom_status,
       a.turned_in_reported_at,
       a.turned_in_reported_by,
       a.turned_in_method,
       a.turned_in_note,
       case
         when a.status in ('submitted','graded','returned','turned_in') then 'agreed'
         when a.turned_in_reported_at is null                           then 'unreported'
         when a.turned_in_reported_at
              < now() - make_interval(days => public.turned_in_grace_days()) then 'disputed'
         else 'reported_only'
       end as reconciliation_state,
       case when a.turned_in_reported_at is not null
            then (current_date - a.turned_in_reported_at::date) end as days_since_report,
       a.archived
  from public.school_assignments a;

comment on view public.v_school_assignment_reconciliation is
  'CLSRM-39: Classroom''s view and the child''s claim side by side. disputed = claimed, grace window elapsed, teacher still has it as missing — the state worth acting on.';

-- Reporting path. SECURITY INVOKER so the caller's own RLS decides which rows
-- they may touch (SB-448's lesson: a definer function here would let any
-- authenticated caller stamp a report on another family's assignment).
create or replace function public.report_assignment_turned_in(
  p_assignment_id uuid,
  p_reported_by   text,
  p_method        text default 'physical',
  p_note          text default null,
  p_reported_at   timestamptz default now()
) returns public.school_assignments
language plpgsql security invoker
set search_path to 'public', 'pg_temp'
as $$
declare r public.school_assignments;
begin
  if coalesce(btrim(p_reported_by),'') = '' then
    raise exception 'CLSRM-39: a hand-in report must say who reported it';
  end if;
  if p_reported_at > now() + interval '1 hour' then
    raise exception 'CLSRM-39: hand-in reported in the future (%)', p_reported_at;
  end if;

  update public.school_assignments
     set turned_in_reported_at = p_reported_at,
         turned_in_reported_by = btrim(p_reported_by),
         turned_in_method      = p_method,
         turned_in_note        = p_note,
         updated_at            = now()
   where id = p_assignment_id
  returning * into r;

  if not found then
    -- RLS filters rather than errors, so "no row" means absent OR not yours.
    raise exception 'CLSRM-39: assignment % not found, or not visible to you', p_assignment_id;
  end if;
  return r;
end $$;

create or replace function public.clear_assignment_turned_in_report(
  p_assignment_id uuid
) returns public.school_assignments
language plpgsql security invoker
set search_path to 'public', 'pg_temp'
as $$
declare r public.school_assignments;
begin
  update public.school_assignments
     set turned_in_reported_at = null,
         turned_in_reported_by = null,
         turned_in_method      = null,
         turned_in_note        = null,
         updated_at            = now()
   where id = p_assignment_id
  returning * into r;

  if not found then
    raise exception 'CLSRM-39: assignment % not found, or not visible to you', p_assignment_id;
  end if;
  return r;
end $$;

comment on function public.report_assignment_turned_in(uuid,text,text,text,timestamptz) is
  'CLSRM-39: record a hand-in made outside Classroom. SECURITY INVOKER — the caller''s RLS decides which rows they can touch.';
comment on function public.clear_assignment_turned_in_report(uuid) is
  'CLSRM-39: retract a hand-in report. Matters as much as setting one: a self-report is the input most likely to need undoing.';

-- ACL by role name; REVOKE FROM PUBLIC leaves the default-ACL grants in place (SB-447).
revoke all on function public.report_assignment_turned_in(uuid,text,text,text,timestamptz) from public, anon;
revoke all on function public.clear_assignment_turned_in_report(uuid) from public, anon;
grant execute on function public.report_assignment_turned_in(uuid,text,text,text,timestamptz) to authenticated, service_role;
grant execute on function public.clear_assignment_turned_in_report(uuid) to authenticated, service_role;

do $$
begin
  if has_function_privilege('anon','public.report_assignment_turned_in(uuid,text,text,text,timestamptz)','execute')
     or has_function_privilege('anon','public.clear_assignment_turned_in_report(uuid)','execute') then
    raise exception 'CLSRM-39: anon can execute a hand-in reporting function';
  end if;
  if (select prosecdef from pg_proc
      where oid='public.report_assignment_turned_in(uuid,text,text,text,timestamptz)'::regprocedure) then
    raise exception 'CLSRM-39: report_assignment_turned_in must be SECURITY INVOKER';
  end if;
  if not exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
                 where n.nspname='public' and c.relname='v_school_assignment_reconciliation'
                   and coalesce((select option_value::boolean from pg_options_to_table(c.reloptions)
                                 where option_name='security_invoker'), false)) then
    raise exception 'CLSRM-39: the reconciliation view must be security_invoker';
  end if;
end $$;;
