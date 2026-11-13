-- Chat with the AI coach. The runner asks anything about their running, a run
-- or their plan; the coach answers, and when the runner wants their plan
-- changed it suggests a change as a program review with trigger 'chat', which
-- is accepted, dismissed or undone like any other suggestion.

alter table public.program_reviews drop constraint program_reviews_trigger_check;
alter table public.program_reviews
  add constraint program_reviews_trigger_check check (trigger in ('run', 'missed', 'chat'));

-- ---------------------------------------------------------------------------
-- Coach messages: one conversation per runner, written by the coach-chat function.
-- ---------------------------------------------------------------------------
create table public.coach_messages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  role text not null check (role in ('user', 'assistant')),
  -- The runner's message, or the coach's reply (saved as it's written while generating).
  content text not null default '',
  status text not null default 'ready' check (status in ('generating', 'ready', 'failed')),
  -- The run the runner asked about, when they asked from a run in History.
  record_id uuid references public.workout_records (id) on delete set null,
  -- The plan the coach answered with, for replies.
  program_id uuid references public.programs (id) on delete set null,
  -- A plan change the coach suggested in this reply.
  review_id uuid references public.program_reviews (id) on delete set null,
  error text,
  model text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index coach_messages_user_id_idx on public.coach_messages (user_id, created_at desc);

create trigger coach_messages_set_updated_at
  before update on public.coach_messages
  for each row execute function public.set_updated_at();

alter table public.coach_messages enable row level security;

-- New tables aren't exposed to the Data API without an explicit grant.
grant select, insert, update, delete on table public.coach_messages to authenticated;

create policy "Users read their own coach messages"
  on public.coach_messages for select to authenticated
  using ((select auth.uid()) = user_id);

create policy "Users create their own coach messages"
  on public.coach_messages for insert to authenticated
  with check ((select auth.uid()) = user_id);

create policy "Users update their own coach messages"
  on public.coach_messages for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy "Users delete their own coach messages"
  on public.coach_messages for delete to authenticated
  using ((select auth.uid()) = user_id);
