-- The onboarding answers each plan was built from. Building a new plan asks
-- the questions again, so a plan's answers can differ from the profile's.
alter table public.programs
  add column onboarding jsonb;
