begin;

create extension if not exists pgtap with schema extensions;
set local search_path to public, extensions;

select plan(32);

insert into auth.users (id) values
  ('75000000-0000-4000-8000-000000000001'),
  ('75000000-0000-4000-8000-000000000002'),
  ('75000000-0000-4000-8000-000000000003');

insert into private.players (id, discord_id, auth_user_id) values
  ('75100000-0000-4000-8000-000000000001', '750000000000000001', '75000000-0000-4000-8000-000000000001'),
  ('75100000-0000-4000-8000-000000000002', '750000000000000002', '75000000-0000-4000-8000-000000000002'),
  ('75100000-0000-4000-8000-000000000003', '750000000000000003', null);
insert into private.staff_actors (player_id) values ('75100000-0000-4000-8000-000000000001');
insert into private.staff_capabilities (staff_actor_id, capability) values
  ('75100000-0000-4000-8000-000000000001', 'characters.review'),
  ('75100000-0000-4000-8000-000000000001', 'boosts.manage');

insert into private.characters (id, player_id, kind, use_status) values
  ('75200000-0000-4000-8000-000000000001', '75100000-0000-4000-8000-000000000002', 'teacher', 'active'),
  ('75200000-0000-4000-8000-000000000002', '75100000-0000-4000-8000-000000000002', 'staff_member', 'suspended'),
  ('75200000-0000-4000-8000-000000000003', '75100000-0000-4000-8000-000000000002', 'student', 'active'),
  ('75200000-0000-4000-8000-000000000004', '75100000-0000-4000-8000-000000000001', 'citizen', 'active');
insert into private.character_sheets (character_id, sexual_orientation, backstory) values
  ('75200000-0000-4000-8000-000000000001', 'Fictional orientation', 'Private fictional backstory');
insert into private.character_reviews (id, character_id, player_id, reviewer_id, decision) values
  ('75300000-0000-4000-8000-000000000001', '75200000-0000-4000-8000-000000000001',
    '75100000-0000-4000-8000-000000000002', '75100000-0000-4000-8000-000000000001', 'approved'),
  ('75300000-0000-4000-8000-000000000002', '75200000-0000-4000-8000-000000000002',
    '75100000-0000-4000-8000-000000000002', '75100000-0000-4000-8000-000000000001', 'approved');
update private.characters c set validation_status = 'approved', current_review_id = r.id
  from private.character_reviews r where r.character_id = c.id
    and r.id in ('75300000-0000-4000-8000-000000000001', '75300000-0000-4000-8000-000000000002');
update private.characters set validation_status = 'submitted' where id = '75200000-0000-4000-8000-000000000003';

-- Invoke under the Data API role using a transaction-local claims fixture.
-- Real Auth signatures are covered separately by the local service suite.
create function pg_temp.call_context(claims jsonb) returns jsonb
language plpgsql security invoker as $$
declare context jsonb;
begin
  perform set_config('request.jwt.claims', claims::text, true);
  set local role authenticated;
  select public.current_player_context() into context;
  reset role;
  return context;
end;
$$;

create function pg_temp.statement_status(role_name text, statement text) returns text
language plpgsql security invoker as $$
begin
  execute format('set local role %I', role_name);
  execute statement;
  reset role;
  return '00000';
exception when others then
  return sqlstate;
end;
$$;

create temp table auth_context_fixture (actor jsonb, teacher jsonb, unlinked jsonb);
insert into auth_context_fixture values
  ('{"sub":"75000000-0000-4000-8000-000000000001","role":"authenticated","is_anonymous":false}',
   '{"sub":"75000000-0000-4000-8000-000000000002","role":"authenticated","is_anonymous":false,
    "user_metadata":{"playerId":"75100000-0000-4000-8000-000000000001","role":"service_role","capabilities":["characters.review","boosts.manage"]}}',
   '{"sub":"75000000-0000-4000-8000-000000000003","role":"authenticated","is_anonymous":false}');

select ok((select relrowsecurity from pg_class where oid = 'private.staff_capabilities'::regclass),
  'new staff grants have RLS');
select ok(not has_schema_privilege('authenticated', 'private', 'USAGE'),
  'private schema lookup is denied even to authenticated');
select ok(not has_column_privilege('authenticated', 'private.players', 'discord_id', 'SELECT'),
  'Discord IDs have no authenticated grant');
select ok(not has_table_privilege('authenticated', 'private.character_sheets', 'SELECT'),
  'private sheets have no authenticated grant');
select ok(not has_table_privilege('authenticated', 'private.character_reviews', 'SELECT'),
  'reviews have no authenticated grant');
select ok(not has_table_privilege('authenticated', 'private.staff_actors', 'SELECT'),
  'staff registry has no authenticated grant');
select ok(has_column_privilege('authenticated', 'private.characters', 'validation_status', 'SELECT'),
  'invoker has the required state column grant');
select ok(not has_column_privilege('authenticated', 'private.characters', 'current_review_id', 'SELECT'),
  'review references are excluded from the invoker grant');
select ok(not has_column_privilege('authenticated', 'private.staff_capabilities', 'granted_at', 'SELECT'),
  'permission grant timestamps are excluded from the invoker grant');
select ok(not has_function_privilege('anon', 'public.current_player_context()', 'EXECUTE'),
  'anonymous RPC callers do not have execute privilege');
select ok((select not prosecdef from pg_proc where oid = 'public.current_player_context()'::regprocedure),
  'the RPC runs with invoker rights');
select ok(has_function_privilege('authenticated', 'public.current_player_context()', 'EXECUTE'),
  'authenticated callers may execute the bounded RPC');

select is(pg_temp.statement_status('anon', 'select public.current_player_context()'),
  '42501', 'anonymous direct RPC calls fail');
select is(pg_temp.statement_status('authenticated', 'select public.current_player_context(gen_random_uuid())'),
  '42883', 'the RPC has no user or character selector');
select is((select pg_temp.call_context(unlinked) from auth_context_fixture), null::jsonb,
  'an unmatched account returns no player context');
select is(pg_temp.call_context('{}'), null::jsonb, 'a missing authenticated subject yields no data');
select is((select pg_temp.call_context(teacher || '{"is_anonymous":true}') from auth_context_fixture),
  null::jsonb, 'a linked anonymous subject yields no data');
select is((select pg_temp.call_context(teacher - 'is_anonymous') from auth_context_fixture),
  null::jsonb, 'the permanent-account claim must be present');

select is((select pg_temp.call_context(actor)->'capabilities' from auth_context_fixture),
  '["characters.review","boosts.manage"]'::jsonb, 'only explicit HRP grants are returned');
select is((select pg_temp.call_context(teacher)->'capabilities' from auth_context_fixture),
  '[]'::jsonb, 'RP teacher and staff_member roles and forged metadata grant no HRP permission');
select is((select pg_temp.call_context(teacher)->>'playerId' from auth_context_fixture),
  '75100000-0000-4000-8000-000000000002', 'the Auth subject determines the player despite forged metadata');
select is((select jsonb_array_length(pg_temp.call_context(teacher)->'characters') from auth_context_fixture),
  3, 'only the three owned characters are returned');
select ok((select not (pg_temp.call_context(teacher)->'characters' @>
  '[{"id":"75200000-0000-4000-8000-000000000004"}]'::jsonb) from auth_context_fixture),
  'a different player character cannot appear in the result');
select is((select pg_temp.call_context(teacher)#>>'{characters,0,canAccessCampus}' from auth_context_fixture),
  'true', 'an approved and active character is eligible');
select is((select pg_temp.call_context(teacher)#>>'{characters,1,canAccessCampus}' from auth_context_fixture),
  'false', 'an approved and suspended character is ineligible');
select is((select pg_temp.call_context(teacher)#>>'{characters,2,canAccessCampus}' from auth_context_fixture),
  'false', 'an active and submitted character is ineligible');
select is((select pg_temp.call_context(actor)->>'canAccessCampus' from auth_context_fixture),
  'false', 'an HRP grant does not bypass the character status');
select is(pg_temp.statement_status('authenticated', 'select * from private.character_sheets'),
  '42501', 'direct private-sheet access fails');
select is(pg_temp.statement_status('authenticated', 'update private.characters set validation_status = ''approved'''),
  '42501', 'authenticated users cannot approve characters');
select is(pg_temp.statement_status('authenticated', 'delete from private.staff_capabilities'),
  '42501', 'authenticated users cannot change grants');
select is(pg_temp.statement_status('authenticated', 'select * from public.character_profiles'),
  '42501', 'public-schema RP profiles remain inaccessible');

delete from private.staff_capabilities
  where staff_actor_id = '75100000-0000-4000-8000-000000000001' and capability = 'characters.review';
select is((select pg_temp.call_context(actor)->'capabilities' from auth_context_fixture),
  '["boosts.manage"]'::jsonb, 'the next resolution reflects a revoked grant with identical claims');

select * from finish();
rollback;
