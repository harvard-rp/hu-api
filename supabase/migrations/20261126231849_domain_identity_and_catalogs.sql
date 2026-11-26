create schema private;
revoke all on schema private from public, anon, authenticated, service_role;

create table private.players (
  id uuid primary key default gen_random_uuid(),
  discord_id text not null unique constraint players_discord_id_snowflake check (
    discord_id ~ '^[1-9][0-9]{0,19}$'
    and (length(discord_id) < 20 or discord_id collate "C" <= '18446744073709551615')
  ),
  auth_user_id uuid unique references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- HRP actor identities are managed by the database operator until HU-005.
create table private.staff_actors (
  player_id uuid primary key references private.players(id),
  created_at timestamptz not null default now()
);

-- Each entry records a confirmed absolute count, never a permanent slot delta.
create table private.boost_confirmations (
  id uuid primary key default gen_random_uuid(),
  revision bigint generated always as identity unique,
  player_id uuid not null references private.players(id),
  confirmed_active_boosts integer not null check (confirmed_active_boosts >= 0),
  confirmation_source text not null default 'staff_manual' check (btrim(confirmation_source) <> ''),
  confirmed_by uuid not null references private.staff_actors(player_id),
  reason text not null check (btrim(reason) <> ''),
  confirmed_at timestamptz not null default now()
);

create index boost_confirmations_player_revision_idx
  on private.boost_confirmations (player_id, revision desc);
create index boost_confirmations_actor_idx on private.boost_confirmations (confirmed_by);

create view private.player_slot_capacity with (security_invoker = true) as
select
  p.id as player_id,
  coalesce(b.confirmed_active_boosts, 0) as confirmed_active_boosts,
  5 + coalesce(b.confirmed_active_boosts, 0)::bigint as allowed_slots
from private.players p
left join lateral (
  select confirmed_active_boosts
  from private.boost_confirmations
  where player_id = p.id
  order by revision desc
  limit 1
) b on true;

create table public.houses (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name text not null check (btrim(name) <> ''),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.programs (like public.houses including all);

create table public.clubs (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name text not null check (btrim(name) <> ''),
  is_active boolean not null default true,
  member_capacity integer check (member_capacity > 0),
  capacity_key integer generated always as (coalesce(member_capacity, 0)) stored,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint clubs_capacity_key_unique unique (id, capacity_key),
  constraint clubs_bde_capacity check (
    (id = '30000000-0000-4000-8000-000000000001') = (slug = 'bde')
    and (slug <> 'bde' or member_capacity is not distinct from 10)
  )
);

create function private.set_updated_at() returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at := statement_timestamp();
  return new;
end;
$$;

create trigger players_set_updated_at before update on private.players
  for each row execute function private.set_updated_at();
create trigger houses_set_updated_at before update on public.houses
  for each row execute function private.set_updated_at();
create trigger programs_set_updated_at before update on public.programs
  for each row execute function private.set_updated_at();
create trigger clubs_set_updated_at before update on public.clubs
  for each row execute function private.set_updated_at();

alter table private.players enable row level security;
alter table private.staff_actors enable row level security;
alter table private.boost_confirmations enable row level security;
alter table public.houses enable row level security;
alter table public.programs enable row level security;
alter table public.clubs enable row level security;

revoke all on private.players, private.staff_actors, private.boost_confirmations,
  private.player_slot_capacity, public.houses, public.programs, public.clubs
  from public, anon, authenticated, service_role;
revoke all on sequence private.boost_confirmations_revision_seq
  from public, anon, authenticated, service_role;
revoke all on function private.set_updated_at()
  from public, anon, authenticated, service_role;
