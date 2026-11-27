-- The function owner has only scoped reads and a player insert. The Supabase
-- migration role can grant Auth SELECT and manage Auth policies via Supautils.
create role hu_player_bootstrap nologin noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls;
grant hu_player_bootstrap to postgres with inherit false, set true;

create schema account_bootstrap;
revoke all on schema account_bootstrap from public, anon, authenticated, service_role;
grant usage on schema account_bootstrap to authenticated;
grant usage, create on schema account_bootstrap to hu_player_bootstrap;
grant usage on schema private to hu_player_bootstrap;

grant select (id, is_anonymous, banned_until) on auth.users to hu_player_bootstrap;
grant select (id, user_id, not_after) on auth.sessions to hu_player_bootstrap;
grant select (user_id, provider, provider_id, identity_data) on auth.identities to hu_player_bootstrap;

create policy hu_bootstrap_read_user on auth.users for select to hu_player_bootstrap
  using (id = (select auth.uid()));
create policy hu_bootstrap_read_session on auth.sessions for select to hu_player_bootstrap
  using (user_id = (select auth.uid()));
create policy hu_bootstrap_read_identity on auth.identities for select to hu_player_bootstrap
  using (user_id = (select auth.uid()) and provider = 'discord');

grant select (discord_id, auth_user_id), insert (discord_id, auth_user_id)
  on private.players to hu_player_bootstrap;
create policy players_bootstrap_read_own on private.players for select to hu_player_bootstrap
  using (auth_user_id = (select auth.uid()));
create policy players_bootstrap_insert_own on private.players for insert to hu_player_bootstrap
  with check (auth_user_id = (select auth.uid()));

-- Resolve Auth references at creation time. The invoker needs the three
-- read grants and passes their RLS policies without AUTH schema USAGE.
create function account_bootstrap.current_discord_identity()
returns table (status text, auth_user_id uuid, discord_id text)
language sql
stable
security invoker
set search_path = ''
begin atomic
  with claims as (
    select auth.jwt() as jwt, auth.uid() as caller
  ), eligible_session as (
    select c.caller
    from claims c
    join auth.users u on u.id = c.caller
    join auth.sessions s on s.user_id = u.id
      and s.id = case when c.jwt ->> 'session_id' ~
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        then (c.jwt ->> 'session_id')::uuid end
    where c.jwt ->> 'sub' = c.caller::text
      and c.jwt ->> 'role' = 'authenticated'
      and c.jwt -> 'is_anonymous' = 'false'::jsonb
      and (c.jwt -> 'aud' = '"authenticated"'::jsonb
        or (jsonb_typeof(c.jwt -> 'aud') = 'array' and c.jwt -> 'aud' ? 'authenticated'))
      and case when jsonb_typeof(c.jwt -> 'exp') = 'number'
        then (c.jwt ->> 'exp')::numeric > extract(epoch from clock_timestamp())
        else false end
      and u.is_anonymous is false
      and (u.banned_until is null or u.banned_until <= clock_timestamp())
      and (s.not_after is null or s.not_after > clock_timestamp())
  ), discord_identity as (
    select min(i.provider_id) as discord_id
    from eligible_session s
    join auth.identities i on i.user_id = s.caller and i.provider = 'discord'
    having count(*) = 1 and bool_and(
      i.identity_data -> 'sub' is not distinct from to_jsonb(i.provider_id)
      and (not i.identity_data ? 'provider_id'
        or i.identity_data -> 'provider_id' = to_jsonb(i.provider_id)) is true
      and i.provider_id ~ '^[1-9][0-9]{0,19}$'
      and (length(i.provider_id) < 20 or i.provider_id collate "C" <= '18446744073709551615')
    )
  )
  select case
      when s.caller is null then 'unauthenticated'
      when i.discord_id is null then 'discord_identity_required'
      else 'ok'
    end, s.caller, i.discord_id
  from (select 1) request
  left join eligible_session s on true
  left join discord_identity i on true;
end;

revoke all on function account_bootstrap.current_discord_identity() from public, anon, authenticated, service_role;
grant execute on function account_bootstrap.current_discord_identity() to hu_player_bootstrap;

create function account_bootstrap.initialize_current_player() returns text
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  verified record;
  checked record;
  outcome text;
begin
  select * into verified from account_bootstrap.current_discord_identity();
  if verified.status <> 'ok' then return verified.status; end if;

  -- Only existing unique keys arbitrate the write. No conflict branch updates
  -- a player or reads any other player's record.
  insert into private.players (discord_id, auth_user_id)
    values (verified.discord_id, verified.auth_user_id) on conflict do nothing;

  -- At READ COMMITTED, a new read observes revocation or identity changes
  -- committed while the INSERT was waiting. Roll back a new row in that case.
  select * into checked from account_bootstrap.current_discord_identity();
  if checked.status <> 'ok' or checked.discord_id is distinct from verified.discord_id then
    outcome := case when checked.status <> 'ok' then checked.status else 'discord_identity_required' end;
    raise sqlstate 'P0701';
  end if;

  if exists (
    select 1 from private.players p
    where p.auth_user_id = verified.auth_user_id and p.discord_id = verified.discord_id
  ) then
    return 'ok';
  end if;
  return 'identity_link_conflict';
exception
  when sqlstate 'P0701' then return outcome;
  -- The only INSERT foreign key is to Auth. A concurrent Auth deletion can
  -- win between verification and the foreign key check.
  when foreign_key_violation then return 'unauthenticated';
end;
$function$;

revoke all on function account_bootstrap.initialize_current_player() from public, anon, authenticated, service_role;
grant execute on function account_bootstrap.initialize_current_player() to authenticated;
alter function account_bootstrap.initialize_current_player() owner to hu_player_bootstrap;
revoke create on schema account_bootstrap from hu_player_bootstrap;

create function public.bootstrap_discord_player() returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $function$
declare
  outcome text := account_bootstrap.initialize_current_player();
begin
  if outcome = 'ok' then
    return jsonb_build_object('status', outcome, 'context', public.current_player_context());
  end if;
  return jsonb_build_object('status', outcome);
end;
$function$;

revoke all on function public.bootstrap_discord_player() from public, anon, authenticated, service_role;
grant execute on function public.bootstrap_discord_player() to authenticated;
