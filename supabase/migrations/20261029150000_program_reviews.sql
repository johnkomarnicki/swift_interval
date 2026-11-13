-- AI coach reviews. After a plan session (or a few missed ones) the coach
-- looks at how training is going, always gives short feedback, and can suggest
-- a change to the rest of the plan, which the runner accepts or dismisses.

-- How the runner said a run felt, picked on the Complete screen.
alter table public.workout_records
  add column effort text check (effort in ('easy', 'just_right', 'hard', 'too_hard'));

-- ---------------------------------------------------------------------------
-- Program reviews: written by the review-program function.
-- ---------------------------------------------------------------------------
create table public.program_reviews (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  program_id uuid not null references public.programs (id) on delete cascade,
  -- The run that was reviewed; null for a review of missed sessions.
  record_id uuid references public.workout_records (id) on delete set null,
  trigger text not null check (trigger in ('run', 'missed')),
  status text not null default 'generating'
    check (status in ('generating', 'ready', 'accepted', 'dismissed', 'superseded', 'reverted', 'failed')),
  -- The coach's feedback; always set once the review is ready.
  feedback text,
  -- The suggested change { reason, summary, changes, weeks }, where weeks is the
  -- merged tail of the plan exactly as it's written on accept. Null when the
  -- coach suggests no change.
  proposal jsonb,
  -- programs.plan from before an accepted change, so it can be undone.
  previous_plan jsonb,
  error text,
  model text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- When the runner accepted or dismissed it, or a newer suggestion replaced it.
  resolved_at timestamptz
);

create index program_reviews_user_id_idx on public.program_reviews (user_id, created_at desc);
create index program_reviews_program_id_idx on public.program_reviews (program_id, created_at desc);
-- One review per run, so a retried request never pays for a second one.
create unique index program_reviews_record_id_idx on public.program_reviews (record_id);

create trigger program_reviews_set_updated_at
  before update on public.program_reviews
  for each row execute function public.set_updated_at();

alter table public.program_reviews enable row level security;

-- New tables aren't exposed to the Data API without an explicit grant.
grant select, insert, update, delete on table public.program_reviews to authenticated;

create policy "Users read their own reviews"
  on public.program_reviews for select to authenticated
  using ((select auth.uid()) = user_id);

create policy "Users create their own reviews"
  on public.program_reviews for insert to authenticated
  with check ((select auth.uid()) = user_id);

create policy "Users update their own reviews"
  on public.program_reviews for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy "Users delete their own reviews"
  on public.program_reviews for delete to authenticated
  using ((select auth.uid()) = user_id);
