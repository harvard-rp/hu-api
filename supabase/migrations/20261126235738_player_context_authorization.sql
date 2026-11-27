create type private.staff_capability as enum ('characters.review', 'boosts.manage');

create table private.staff_capabilities (
  staff_actor_id uuid not null references private.staff_actors(player_id),
  capability private.staff_capability not null,
  granted_at timestamptz not null default now(),
  primary key (staff_actor_id, capability)
);

alter table private.staff_capabilities enable row level security;
revoke all on private.staff_capabilities from public, anon, authenticated, service_role;

-- These grants support the pre-parsed invoker function. The private schema
-- stays off the Data API and authenticated receives no schema USAGE.
grant select (id, auth_user_id) on private.players to authenticated;
grant select (id, player_id, validation_status, use_status) on private.characters to authenticated;
grant select (staff_actor_id, capability) on private.staff_capabilities to authenticated;

create policy players_read_linked_account on private.players
  for select to authenticated
  using (auth_user_id = (select auth.uid()));

create policy players_require_permanent_account on private.players
  as restrictive for select to authenticated
  using ((select auth.jwt() -> 'is_anonymous') = 'false'::jsonb);

create policy characters_read_own_status on private.characters
  for select to authenticated
  using (exists (
    select 1 from private.players p
    where p.id = player_id and p.auth_user_id = (select auth.uid())
  ));

create policy staff_capabilities_read_own_grants on private.staff_capabilities
  for select to authenticated
  using (exists (
    select 1 from private.players p
    where p.id = staff_actor_id and p.auth_user_id = (select auth.uid())
  ));

-- SQL-standard function bodies resolve object references when created. The
-- caller needs column privileges and passes RLS, with no private schema grant.
create function public.current_player_context() returns jsonb
language sql
stable
security invoker
set search_path = ''
begin atomic
  select jsonb_build_object(
    'playerId', p.id,
    'capabilities', coalesce((
      select jsonb_agg(g.capability order by g.capability)
      from private.staff_capabilities g
      where g.staff_actor_id = p.id
    ), '[]'::jsonb),
    'characters', coalesce(c.characters, '[]'::jsonb),
    'canAccessCampus', coalesce(c.can_access_campus, false)
  )
  from private.players p
  cross join lateral (
    select
      jsonb_agg(jsonb_build_object(
        'id', owned.id,
        'validationStatus', owned.validation_status,
        'useStatus', owned.use_status,
        'canAccessCampus', owned.can_access_campus
      ) order by owned.id) as characters,
      bool_or(owned.can_access_campus) as can_access_campus
    from (
      select
        ch.id, ch.validation_status, ch.use_status,
        ch.validation_status = 'approved' and ch.use_status = 'active' as can_access_campus
      from private.characters ch
      where ch.player_id = p.id
    ) owned
  ) c
  where p.auth_user_id = (select auth.uid());
end;

revoke all on function public.current_player_context() from public, anon, authenticated, service_role;
grant execute on function public.current_player_context() to authenticated;
