-- Runwise: accounts, onboarding, synced workouts/history, and AI programs.
-- Every table is protected by row level security so a user can only ever
-- read or change their own rows.

-- Keeps updated_at current on every update.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Profiles: one row per user, created automatically at sign-up.
-- ---------------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  -- Answers from the onboarding questions (see OnboardingAnswers in the app).
  onboarding jsonb,
  onboarding_completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id) values (new.id);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

alter table public.profiles enable row level security;

create policy "Users read their own profile"
  on public.profiles for select to authenticated
  using ((select auth.uid()) = id);

create policy "Users update their own profile"
  on public.profiles for update to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

-- ---------------------------------------------------------------------------
-- Programs: AI-generated training plans.
-- ---------------------------------------------------------------------------
create table public.programs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  status text not null default 'generating'
    check (status in ('generating', 'active', 'archived', 'failed')),
  start_date date,
  title text,
  summary text,
  -- The plan: weeks -> sessions -> workout (same shape as WorkoutPlan in the app).
  plan jsonb,
  error text,
  model text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index programs_user_id_idx on public.programs (user_id, created_at desc);

create trigger programs_set_updated_at
  before update on public.programs
  for each row execute function public.set_updated_at();

alter table public.programs enable row level security;

create policy "Users read their own programs"
  on public.programs for select to authenticated
  using ((select auth.uid()) = user_id);

create policy "Users create their own programs"
  on public.programs for insert to authenticated
  with check ((select auth.uid()) = user_id);

create policy "Users update their own programs"
  on public.programs for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy "Users delete their own programs"
  on public.programs for delete to authenticated
  using ((select auth.uid()) = user_id);

-- ---------------------------------------------------------------------------
-- Workouts: the user's saved workouts (synced from the app).
-- ---------------------------------------------------------------------------
create table public.workouts (
  -- Generated on the phone so offline edits keep a stable id.
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name text not null default '',
  -- WorkoutPlan from the app, as JSON.
  plan jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index workouts_user_id_idx on public.workouts (user_id);

alter table public.workouts enable row level security;

create policy "Users read their own workouts"
  on public.workouts for select to authenticated
  using ((select auth.uid()) = user_id);

create policy "Users create their own workouts"
  on public.workouts for insert to authenticated
  with check ((select auth.uid()) = user_id);

create policy "Users update their own workouts"
  on public.workouts for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy "Users delete their own workouts"
  on public.workouts for delete to authenticated
  using ((select auth.uid()) = user_id);

-- ---------------------------------------------------------------------------
-- Workout records: run history with per-interval distance and pace.
-- ---------------------------------------------------------------------------
create table public.workout_records (
  -- Generated on the phone so offline runs keep a stable id.
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name text not null default '',
  started_at timestamptz not null,
  completed boolean not null default true,
  total_time double precision not null default 0,
  active_time double precision not null default 0,
  total_meters double precision,
  -- [IntervalResult] from the app, as JSON.
  intervals jsonb not null default '[]'::jsonb,
  -- Set when the run was a session from an AI program.
  program_id uuid references public.programs (id) on delete set null,
  program_session_id text,
  created_at timestamptz not null default now()
);

create index workout_records_user_id_idx on public.workout_records (user_id, started_at desc);
create index workout_records_program_id_idx on public.workout_records (program_id);

alter table public.workout_records enable row level security;

create policy "Users read their own records"
  on public.workout_records for select to authenticated
  using ((select auth.uid()) = user_id);

create policy "Users create their own records"
  on public.workout_records for insert to authenticated
  with check ((select auth.uid()) = user_id);

create policy "Users update their own records"
  on public.workout_records for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy "Users delete their own records"
  on public.workout_records for delete to authenticated
  using ((select auth.uid()) = user_id);
