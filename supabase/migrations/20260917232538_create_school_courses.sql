create table if not exists public.school_courses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  child_project_id uuid not null,
  child_name text not null,
  school_year text not null default '2026-27',
  school text,
  course_name text not null,
  classroom_name text,
  period text,
  day_pattern text,
  room text,
  teacher_of_record text,
  teacher_email text,
  co_teacher text,
  co_teacher_email text,
  is_ict boolean,
  ict_verified_on date,
  ict_evidence text,
  iep_mandated boolean default false,
  grading_policy text,
  extra_help text,
  materials text,
  notes text,
  source text,
  source_date date,
  archived boolean default false,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  unique (child_project_id, school_year, course_name)
);

create index if not exists school_courses_child_idx on public.school_courses (child_project_id, school_year) where archived = false;

alter table public.school_courses enable row level security;

drop policy if exists school_courses_owner on public.school_courses;
create policy school_courses_owner on public.school_courses
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);;
