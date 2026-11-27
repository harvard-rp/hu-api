begin;

create extension if not exists pgtap with schema extensions;
set local search_path to public, extensions;

select plan(27);

-- Use the unsigned integer boundary as a synthetic snowflake fixture.
create function pg_temp.signup_event(provider text, subject jsonb, provider_id jsonb) returns jsonb
language sql immutable
as $$
  select jsonb_build_object(
    'metadata', jsonb_build_object('name', 'before-user-created'),
    'user', jsonb_build_object(
      'app_metadata', jsonb_build_object('provider', provider, 'providers', jsonb_build_array(provider)),
      'user_metadata', jsonb_build_object('sub', subject, 'provider_id', provider_id),
      'is_anonymous', false,
      'identities', '[]'::jsonb
    )
  )
$$;

create function pg_temp.signup_denied(event jsonb) returns boolean
language sql stable
as $$
  select signup_guard.before_user_created(event)
    = '{"error":{"http_code":403,"message":"Registration is restricted."}}'::jsonb
$$;

create temporary table signup_fixture as
select pg_temp.signup_event('discord', '"18446744073709551615"', '"18446744073709551615"') as event,
  (select count(*) from auth.users) as users,
  (select count(*) from private.players) as players,
  (select count(*) from private.staff_capabilities) as staff_grants;

select is((select count(*) from signup_guard.discord_allowlist), 0::bigint,
  'the migration leaves the allowlist empty');
select ok((select pg_temp.signup_denied(event) from signup_fixture),
  'a valid Discord identity is denied when the allowlist is empty');

insert into signup_guard.discord_allowlist (discord_id) values ('18446744073709551615');

select is((select signup_guard.before_user_created(event) from signup_fixture), '{}'::jsonb,
  'a matching pre-insert Discord callback is accepted');
select ok(pg_temp.signup_denied(pg_temp.signup_event('discord', '"18446744073709551614"', '"18446744073709551614"')),
  'an unlisted Discord subject receives the generic denial');
select ok((select pg_temp.signup_denied(jsonb_set(event, '{user,app_metadata,provider}', '"email"')) from signup_fixture),
  'a forged Discord subject cannot turn email signup into Discord signup');
select ok((select pg_temp.signup_denied(jsonb_set(event, '{user,app_metadata,providers}', '["discord","email"]')) from signup_fixture),
  'multiple asserted providers are denied');
select ok((select pg_temp.signup_denied(jsonb_set(event, '{user,is_anonymous}', 'true')) from signup_fixture),
  'an anonymous signup is denied');
select ok((select pg_temp.signup_denied(event #- '{user,is_anonymous}') from signup_fixture),
  'a missing anonymous marker is denied');
select ok((select pg_temp.signup_denied(event #- '{user,app_metadata}') from signup_fixture),
  'caller-editable metadata without a server provider is denied');
select ok((select pg_temp.signup_denied(event #- '{user,user_metadata,sub}') from signup_fixture),
  'a missing subject is denied');
select ok((select pg_temp.signup_denied(event #- '{user,user_metadata,provider_id}') from signup_fixture),
  'a missing provider ID is denied');
select ok((select pg_temp.signup_denied(jsonb_set(event, '{user,user_metadata,provider_id}', '"18446744073709551614"')) from signup_fixture),
  'inconsistent Discord IDs are denied');
select ok(pg_temp.signup_denied(pg_temp.signup_event('discord', '18446744073709551615', '18446744073709551615')),
  'a JSON number is denied even when its decimal digits are allowlisted');
select ok((select pg_temp.signup_denied(jsonb_set(event, '{user,user_metadata,sub}', '["18446744073709551615"]')) from signup_fixture),
  'an array of subjects is denied');
select ok((select pg_temp.signup_denied(jsonb_set(event, '{user,identities}', '[{"provider":"discord"},{"provider":"discord"}]')) from signup_fixture),
  'a payload with multiple identity records is denied');
select ok((select pg_temp.signup_denied(event #- '{user,identities}') from signup_fixture),
  'an unexpected identity payload shape fails closed');
select ok((select pg_temp.signup_denied(event #- '{metadata,name}') from signup_fixture),
  'a different hook payload is denied');
select ok(pg_temp.signup_denied('{}'::jsonb), 'an empty event is denied');
select ok(pg_temp.signup_denied(null), 'a SQL null event is denied');
select throws_ok($$insert into signup_guard.discord_allowlist values ('00123')$$, '23514', null,
  'the operator cannot store a leading-zero snowflake');
select throws_ok($$insert into signup_guard.discord_allowlist values ('18446744073709551616')$$, '23514', null,
  'the operator cannot store a snowflake beyond uint64');

select ok((select relrowsecurity from pg_class where oid = 'signup_guard.discord_allowlist'::regclass),
  'the allowlist uses RLS');
select ok((select not prosecdef from pg_proc where oid = 'signup_guard.before_user_created(jsonb)'::regprocedure),
  'the hook uses invoker privileges');
select ok(has_schema_privilege('supabase_auth_admin', 'signup_guard', 'USAGE')
  and has_function_privilege('supabase_auth_admin', 'signup_guard.before_user_created(jsonb)', 'EXECUTE')
  and has_column_privilege('supabase_auth_admin', 'signup_guard.discord_allowlist', 'discord_id', 'SELECT'),
  'GoTrue has the required schema, hook and lookup privileges');
select ok(not has_table_privilege('supabase_auth_admin', 'signup_guard.discord_allowlist', 'INSERT, UPDATE, DELETE, TRUNCATE'),
  'GoTrue cannot write the allowlist');
select ok(not exists (
  select from unnest(array['anon','authenticated','service_role']) roles(role_name)
  where has_schema_privilege(role_name, 'signup_guard', 'USAGE')
    or has_function_privilege(role_name, 'signup_guard.before_user_created(jsonb)', 'EXECUTE')
    or has_column_privilege(role_name, 'signup_guard.discord_allowlist', 'discord_id', 'SELECT')
), 'API roles have no access to the schema, hook or data');

select ok((select users = (select count(*) from auth.users)
  and players = (select count(*) from private.players)
  and staff_grants = (select count(*) from private.staff_capabilities)
  from signup_fixture), 'evaluating the hook creates no accounts, players or HRP grants');

select * from finish();
rollback;
