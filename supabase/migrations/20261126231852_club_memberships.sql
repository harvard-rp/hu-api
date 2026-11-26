create type private.club_membership_status as enum ('active', 'inactive');

create table private.club_memberships (
  id uuid primary key default gen_random_uuid(),
  character_id uuid not null references private.characters(id),
  club_id uuid not null,
  club_capacity_key integer not null default 0,
  status private.club_membership_status not null default 'active',
  character_slot smallint,
  club_seat integer,
  responsibility text check (btrim(responsibility) <> ''),
  joined_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint club_memberships_club_capacity_fk
    foreign key (club_id, club_capacity_key) references public.clubs(id, capacity_key) on update cascade,
  constraint club_memberships_unique_pair unique (character_id, club_id),
  constraint club_memberships_unique_character_slot unique (character_id, character_slot),
  constraint club_memberships_unique_club_seat unique (club_id, club_seat),
  constraint club_memberships_active_slots check (
    (
      status = 'active'
      and character_slot is not null
      and character_slot between 1 and 2
      and (
        (club_capacity_key = 0 and (club_seat is null or club_seat > 0))
        or (club_seat is not null and club_seat between 1 and club_capacity_key)
      )
    )
    or (status = 'inactive' and character_slot is null and club_seat is null)
  )
);

create index club_memberships_club_capacity_idx
  on private.club_memberships (club_id, club_capacity_key);

create trigger club_memberships_set_updated_at before update on private.club_memberships
  for each row execute function private.set_updated_at();
alter table private.club_memberships enable row level security;
revoke all on private.club_memberships from public, anon, authenticated, service_role;
