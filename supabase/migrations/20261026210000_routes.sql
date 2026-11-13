-- ---------------------------------------------------------------------------
-- Routes: runs planned on the map in the app (synced from the app).
-- ---------------------------------------------------------------------------
create table public.routes (
  -- Generated on the phone so offline edits keep a stable id.
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name text not null default '',
  -- [RouteCoordinate] from the app: the points tapped on the map.
  waypoints jsonb not null default '[]'::jsonb,
  -- [[RouteCoordinate]] from the app: the path from each waypoint to the next.
  legs jsonb not null default '[]'::jsonb,
  meters double precision not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index routes_user_id_idx on public.routes (user_id);

alter table public.routes enable row level security;

create policy "Users read their own routes"
  on public.routes for select to authenticated
  using ((select auth.uid()) = user_id);

create policy "Users create their own routes"
  on public.routes for insert to authenticated
  with check ((select auth.uid()) = user_id);

create policy "Users update their own routes"
  on public.routes for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy "Users delete their own routes"
  on public.routes for delete to authenticated
  using ((select auth.uid()) = user_id);

-- Which route each plan session uses: { "<session id>": "<route id>" }.
alter table public.programs
  add column session_routes jsonb not null default '{}'::jsonb;
