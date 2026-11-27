begin;

create extension if not exists pgtap with schema extensions;
set local search_path to public, extensions;

select plan(36);

create function pg_temp.fixture_id(prefix text, fixture integer) returns uuid
language sql immutable as $$
  select (prefix || '0000000-0000-4000-8000-' || lpad(fixture::text, 12, '0'))::uuid
$$;

insert into auth.users (id, is_anonymous)
select pg_temp.fixture_id('a', n), n = 11 from generate_series(1, 13) n;
insert into auth.sessions (id, user_id, not_after)
select pg_temp.fixture_id('b', n), pg_temp.fixture_id('a', n),
  case when n = 12 then now() - interval '1 minute' end
from generate_series(1, 13) n;

insert into auth.identities (id, user_id, provider, provider_id, identity_data)
select gen_random_uuid(), pg_temp.fixture_id('a', n), 'discord', provider_id,
  jsonb_build_object('sub', subject, 'provider_id', provider_id)
from (values
  (1, '18446744073709551615', '18446744073709551615'),
  (3, '890000000000000003', '890000000000000003'),
  (3, '891000000000000003', '891000000000000003'),
  (4, '18446744073709551616', '18446744073709551616'),
  (5, '890000000000000005', '890000000000000099'),
  (6, '890000000000000006', '890000000000000006'),
  (7, '890000000000000007', '890000000000000007'),
  (8, '890000000000000008', '890000000000000008'),
  (9, '890000000000000009', '890000000000000009'),
  (10, '890000000000000010', '890000000000000010'),
  (11, '890000000000000011', '890000000000000011'),
  (12, '890000000000000012', '890000000000000012'),
  (13, '890000000000000013', '890000000000000013')
) fixture(n, provider_id, subject);

insert into private.players (id, auth_user_id, discord_id) values
  (pg_temp.fixture_id('c', 6), pg_temp.fixture_id('a', 2), '890000000000000006'),
  (pg_temp.fixture_id('c', 7), null, '890000000000000007'),
  (pg_temp.fixture_id('c', 8), pg_temp.fixture_id('a', 8), '999000000000000008'),
  (pg_temp.fixture_id('c', 9), pg_temp.fixture_id('a', 9), '890000000000000009');
insert into private.characters (id, player_id, kind) values
  (pg_temp.fixture_id('d', 7), pg_temp.fixture_id('c', 7), 'citizen'),
  (pg_temp.fixture_id('d', 9), pg_temp.fixture_id('c', 9), 'student');

create function pg_temp.claims(fixture integer) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'sub', pg_temp.fixture_id('a', fixture),
    'session_id', pg_temp.fixture_id('b', fixture),
    'role', 'authenticated', 'aud', 'authenticated', 'is_anonymous', false,
    'exp', extract(epoch from now() + interval '5 minutes'),
    'user_metadata', jsonb_build_object('provider_id', '890000000000000007', 'provider', 'discord', 'role', 'service_role')
  )
$$;

create function pg_temp.call_bootstrap(claims jsonb) returns jsonb
language plpgsql security invoker as $$
declare result jsonb;
begin
  perform set_config('request.jwt.claims', claims::text, true);
  set local role authenticated;
  select public.bootstrap_discord_player() into result;
  reset role;
  return result;
end;
$$;

select is(pg_temp.call_bootstrap(pg_temp.claims(2))->>'status', 'discord_identity_required',
  'user metadata cannot supply a Discord identity');
select is(pg_temp.call_bootstrap(pg_temp.claims(3))->>'status', 'discord_identity_required',
  'multiple Discord identities are ambiguous');
select is(pg_temp.call_bootstrap(pg_temp.claims(4))->>'status', 'discord_identity_required',
  'a snowflake above the uint64 maximum is invalid');
select is(pg_temp.call_bootstrap(pg_temp.claims(5))->>'status', 'discord_identity_required',
  'a Discord provider ID must agree with the stored provider subject');
select is(pg_temp.call_bootstrap(pg_temp.claims(6))->>'status', 'identity_link_conflict',
  'a Discord account already linked to a different Auth user cannot be claimed');
select is(pg_temp.call_bootstrap(pg_temp.claims(7))->>'status', 'identity_link_conflict',
  'an unlinked historical player cannot be claimed');
select is(pg_temp.call_bootstrap(pg_temp.claims(8))->>'status', 'identity_link_conflict',
  'an Auth user already linked to a different Discord account cannot be transferred');

select is(pg_temp.call_bootstrap(pg_temp.claims(10) || '{"exp":1}')->>'status',
  'unauthenticated', 'the RPC rejects an expired token even with an existing session');
select is(pg_temp.call_bootstrap(pg_temp.claims(10) || '{"session_id":"bad"}')->>'status',
  'unauthenticated', 'malformed session claim fails closed');
select is(pg_temp.call_bootstrap(pg_temp.claims(10) || jsonb_build_object('session_id', pg_temp.fixture_id('b', 1)))->>'status',
  'unauthenticated', 'a session must belong to the caller');
select is(pg_temp.call_bootstrap(pg_temp.claims(10) || '{"is_anonymous":true}')->>'status',
  'unauthenticated', 'an anonymous JWT cannot bootstrap');
select is(pg_temp.call_bootstrap(pg_temp.claims(11))->>'status', 'unauthenticated',
  'an anonymous Auth row cannot bootstrap even with a permanent-account claim');
select is(pg_temp.call_bootstrap(pg_temp.claims(12))->>'status', 'unauthenticated',
  'the session not_after deadline is enforced');
update auth.users set banned_until = now() + interval '1 hour' where id = pg_temp.fixture_id('a', 13);
select is(pg_temp.call_bootstrap(pg_temp.claims(13))->>'status', 'unauthenticated',
  'an Auth-banned account cannot write through the direct RPC');
delete from auth.sessions where id = pg_temp.fixture_id('b', 10);
select is(pg_temp.call_bootstrap(pg_temp.claims(10))->>'status', 'unauthenticated',
  'the same subject cannot bootstrap after its session is revoked');
select is((select count(*) from private.players), 4::bigint, 'rejected calls left player rows unchanged');

create temp table first_bootstrap as select pg_temp.call_bootstrap(pg_temp.claims(1)) as result;
select is((select result->>'status' from first_bootstrap), 'ok',
  'a valid permanent user with a Discord identity can bootstrap');
select is((select (result->'context') - 'playerId' from first_bootstrap),
  '{"capabilities":[],"characters":[],"canAccessCampus":false}'::jsonb,
  'the first response has no characters, capabilities or campus access');
select is(pg_temp.call_bootstrap(pg_temp.claims(1)), (select result from first_bootstrap),
  'repeating bootstrap gets the same player and context');
select is((select discord_id from private.players where auth_user_id = pg_temp.fixture_id('a', 1)),
  '18446744073709551615', 'the provider ID retains its exact decimal representation');
select is(pg_temp.call_bootstrap(pg_temp.claims(9))#>>'{context,characters,0,id}',
  pg_temp.fixture_id('d', 9)::text, 'a matching existing account returns its own character context');
select is((select count(*) from private.players), 5::bigint, 'only one player was added');

delete from auth.users where id = pg_temp.fixture_id('a', 9);
select ok((select auth_user_id is null from private.players where id = pg_temp.fixture_id('c', 9)),
  'deleting an Auth account clears the association');
select ok(exists(select 1 from private.characters where id = pg_temp.fixture_id('d', 9)),
  'deleting an Auth account preserves the character');
select is(pg_temp.call_bootstrap(pg_temp.claims(9))->>'status', 'unauthenticated',
  'an old token cannot act after Auth account deletion');

select ok(not has_schema_privilege('authenticated', 'private', 'USAGE'), 'private schema remains closed');
select ok(not has_column_privilege('authenticated', 'private.players', 'discord_id', 'INSERT'),
  'authenticated receives no generic player insert');
select ok(not has_function_privilege('anon', 'public.bootstrap_discord_player()', 'EXECUTE'),
  'anonymous has no facade execute grant');
select ok(not has_function_privilege('anon', 'account_bootstrap.initialize_current_player()', 'EXECUTE'),
  'the initializer has no implicit PUBLIC execute privilege');
select ok(not has_function_privilege('authenticated', 'account_bootstrap.current_discord_identity()', 'EXECUTE'),
  'authenticated cannot call the provider identity lookup');
select ok(not has_function_privilege('service_role', 'public.bootstrap_discord_player()', 'EXECUTE'),
  'service_role has no facade execute grant');
select ok((select not prosecdef from pg_proc where oid = 'public.bootstrap_discord_player()'::regprocedure),
  'the exposed facade runs as invoker');
select is((select pg_get_userbyid(proowner) from pg_proc
  where oid = 'account_bootstrap.initialize_current_player()'::regprocedure),
  'hu_player_bootstrap'::name, 'the privileged function has a dedicated owner');
select ok((select not rolcanlogin and not rolsuper and not rolbypassrls and not rolcreaterole
  from pg_roles where rolname = 'hu_player_bootstrap'), 'the function owner has no login or RLS bypass');
select ok(not has_table_privilege('hu_player_bootstrap', 'private.characters', 'SELECT, INSERT, UPDATE, DELETE')
  and not has_table_privilege('hu_player_bootstrap', 'private.staff_capabilities', 'SELECT, INSERT, UPDATE, DELETE')
  and not has_column_privilege('hu_player_bootstrap', 'private.players', 'auth_user_id', 'UPDATE'),
  'the privileged owner cannot change existing links, characters or capabilities');

select ok(not has_column_privilege('hu_player_bootstrap', 'auth.sessions', 'id', 'UPDATE')
  and not has_column_privilege('hu_player_bootstrap', 'auth.identities', 'id', 'UPDATE')
  and not has_column_privilege('hu_player_bootstrap', 'auth.users', 'id', 'UPDATE'),
  'the privileged owner cannot update any Auth rows');

select * from finish();
rollback;
