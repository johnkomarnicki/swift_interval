-- Free runs and walks from the Free Run tab. Null for interval workouts.
alter table public.workout_records
  add column activity text check (activity in ('run', 'walk'));
