create schema signup_guard;
revoke all on schema signup_guard from public, anon, authenticated, service_role;
grant usage on schema signup_guard to supabase_auth_admin;

create table signup_guard.discord_allowlist (
  discord_id text primary key
    constraint discord_allowlist_snowflake check (
      discord_id ~ '^[1-9][0-9]{0,19}$'
      and (length(discord_id) < 20 or discord_id collate "C" <= '18446744073709551615')
    )
);

alter table signup_guard.discord_allowlist enable row level security;
revoke all on signup_guard.discord_allowlist from public, anon, authenticated, service_role, supabase_auth_admin;
grant select (discord_id) on signup_guard.discord_allowlist to supabase_auth_admin;

create policy discord_allowlist_read_for_auth_hook
  on signup_guard.discord_allowlist for select to supabase_auth_admin
  using (true);

create function signup_guard.before_user_created(event jsonb)
returns jsonb
language sql
stable
security invoker
set search_path = ''
begin atomic
  -- GoTrue v2.198.0 constructs this event before writing users/identities.
  -- On the server-marked Discord callback, the two fields under user_metadata
  -- come from Discord /users/@me, before user-editable metadata exists.
  select case when
    event #> '{metadata,name}' = '"before-user-created"'::jsonb
    and event #> '{user,is_anonymous}' = 'false'::jsonb
    and event #> '{user,app_metadata,provider}' = '"discord"'::jsonb
    and event #> '{user,app_metadata,providers}' = '["discord"]'::jsonb
    and event #> '{user,identities}' = '[]'::jsonb
    and jsonb_typeof(event #> '{user,user_metadata,sub}') = 'string'
    and event #> '{user,user_metadata,sub}' = event #> '{user,user_metadata,provider_id}'
    and exists (
      select 1 from signup_guard.discord_allowlist allowed
      where allowed.discord_id = event #>> '{user,user_metadata,sub}'
    )
  then '{}'::jsonb
  else '{"error":{"http_code":403,"message":"Registration is restricted."}}'::jsonb
  end;
end;

revoke all on function signup_guard.before_user_created(jsonb)
  from public, anon, authenticated, service_role;
grant execute on function signup_guard.before_user_created(jsonb) to supabase_auth_admin;
