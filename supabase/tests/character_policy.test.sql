begin;
create extension if not exists pgtap with schema extensions;
set local search_path to public, extensions;
select no_plan();

select ok(character_lifecycle.valid_external_url(link), link)
from unnest(array[
  'https://www.canva.com/design/DA123/token/view?utm_content=fixture',
  'https://www.canva.com/design/DA123/view',
  'https://docs.google.com/document/d/fixture/edit?usp=sharing',
  'https://docs.google.com/document/u/0/d/fixture/preview',
  'https://docs.google.com/document/d/e/fixture/pub',
  'https://sites.google.com/view/fixture/backstory/#section'
]) as input(link);
select ok(not character_lifecycle.valid_external_url(link), link)
from unnest(array[
  'https://canva.com/design/id/edit',
  'https://www.canva.com/design/id/edit',
  'https://docs.google.com.example.test/document/d/fixture/view',
  'https://docs.google.com./document/d/fixture/view',
  'https://docs.google.com@evil.example/document/d/fixture/view',
  'https://user:pass@docs.google.com/document/d/fixture/view',
  'https://docs.google.com:443/document/d/fixture/view',
  'http://sites.google.com/view/fixture',
  'https://docs.google.com/%64ocument/d/fixture/edit',
  'https://docs.google.com/document/d/fixture/edit?bad=%1',
  'https://docs.google.com/document/d/fixture/edit?bad=%ZZ',
  'https://docs.google.com/spreadsheets/d/fixture/edit',
  'https://sites.google.com/view/slug/../other',
  'https://sites.google.com/d/fixture/edit',
  'https://bit.ly/fixture',
  'https://docs.google.com/document/d/fixture/view' || E'\n'
]) as input(link);

select is(character_lifecycle.editorial_lines(E'  A  \r\n \t\rB\rC\nD\n\n  E  \n'), 5, 'explicit nonblank lines');
select is(character_lifecycle.editorial_lines(null), 0, 'a missing narrative has no lines');
select is(character_lifecycle.editorial_lines(U&'\00A0\2007\FEFF'), 0, 'Unicode-only whitespace does not add a line');
select is(character_lifecycle.editorial_lines(repeat('Long text ', 300)), 1, 'visual wrapping does not add lines');

insert into auth.users (id, is_anonymous) values ('009f0000-0000-4000-8000-000000000001', false);
insert into auth.sessions (id, user_id) values
  ('009f0000-0000-4000-8000-000000000002', '009f0000-0000-4000-8000-000000000001');
insert into private.players (id, auth_user_id, discord_id)
values ('009f0000-0000-4000-8000-000000000003', '009f0000-0000-4000-8000-000000000001', '900000000000009090');

create function pg_temp.policy_owner(op text, target_id uuid default null, revision uuid default null,
  payload jsonb default null) returns jsonb language plpgsql as $$
declare result jsonb;
begin
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '009f0000-0000-4000-8000-000000000001', 'session_id', '009f0000-0000-4000-8000-000000000002',
    'aud', 'authenticated', 'role', 'authenticated', 'is_anonymous', false,
    'exp', extract(epoch from clock_timestamp() + interval '5 minutes'))::text, true);
  set local role authenticated;
  select public.player_characters(op, target_id, revision, payload) into result;
  reset role;
  return result;
end;
$$;

create function pg_temp.try_submit(fields jsonb) returns text language plpgsql as $$
declare created jsonb;
declare result text;
begin
  created := pg_temp.policy_owner('create', payload => fields);
  if created ->> 'status' <> 'ok' then return created ->> 'status'; end if;
  result := pg_temp.policy_owner('submit', (created#>>'{data,id}')::uuid, (created#>>'{data,revision}')::uuid)->>'status';
  delete from private.character_sheets where character_id = (created#>>'{data,id}')::uuid;
  delete from public.character_profiles where character_id = (created#>>'{data,id}')::uuid;
  delete from private.characters where id = (created#>>'{data,id}')::uuid;
  return result;
end;
$$;

create temp view submission_cases as
select kind, mode, jsonb_build_object(
  'kind', kind, 'sheetMode', mode, 'firstName', 'Fictional', 'lastName', 'Example',
  'age', 23, 'birthDate', '2003-01-03', 'faceClaim', 'Fictional portrait',
  'occupation', case when kind in ('teacher', 'staff_member') then 'Fictional occupation' end,
  'programId', case when kind = 'student' then (select id from public.programs where is_active limit 1) end
) || case when mode = 'inline' then jsonb_build_object(
  'personality', repeat(E'Curious\r\n', 10), 'physicalDescription', repeat(E'Fictional appearance\r', 5),
  'backstory', repeat(E'Fictional backstory\n', 15)) else
  '{"externalUrl":"https://sites.google.com/view/fixture"}'::jsonb end as fields
from unnest(array['student', 'teacher', 'staff_member', 'citizen']) as kind
cross join unnest(array['inline', 'external']) as mode;
select is(pg_temp.try_submit(fields), 'ok', kind || ' submits in ' || mode) from submission_cases;
select is(pg_temp.try_submit(fields - field), 'incomplete', 'requires ' || kind || ' ' || mode || ' ' || field)
from submission_cases cross join unnest(array['firstName', 'lastName', 'age', 'birthDate', 'faceClaim']) field;
select is(pg_temp.try_submit(fields - 'occupation'), 'incomplete', 'requires occupation for ' || kind || ' ' || mode)
from submission_cases where kind in ('teacher', 'staff_member');
select is(pg_temp.try_submit(fields - 'programId'), 'incomplete', 'requires student program in ' || mode)
from submission_cases where kind = 'student';
select is(pg_temp.try_submit(fields - 'externalUrl'), 'incomplete', 'requires external link for ' || kind)
from submission_cases where mode = 'external';
select is(pg_temp.try_submit(fields || jsonb_build_object('programId', (select id from public.programs where is_active limit 1))),
  'invalid_program', 'program inapplicable to ' || kind)
from submission_cases where mode = 'external' and kind in ('staff_member', 'citizen');
select is(pg_temp.try_submit(fields || '{"isScholarshipHolder":true}'), 'invalid_request', 'scholarship inapplicable to ' || kind)
from submission_cases where mode = 'external' and kind <> 'student';
select is(pg_temp.try_submit(fields || jsonb_build_object(field, repeat(E'Fictional\n', lines))), result,
  field || ' with ' || lines || ' lines')
from submission_cases cross join (values
  ('personality', 4, 'incomplete'), ('personality', 5, 'ok'), ('personality', 11, 'incomplete'),
  ('physicalDescription', 4, 'incomplete'), ('physicalDescription', 20, 'ok'),
  ('backstory', 9, 'incomplete'), ('backstory', 10, 'ok'), ('backstory', 16, 'incomplete')
) as bounds(field, lines, result) where kind = 'citizen' and mode = 'inline';

select ok(not has_any_column_privilege('authenticated', 'private.character_reopen_requests', 'SELECT,INSERT,UPDATE')
  and not has_table_privilege('authenticated', 'private.character_reopen_requests', 'DELETE'),
  'clients have no raw request access');
select ok(not has_function_privilege('anon', 'public.character_reopening(text,uuid,jsonb,integer,uuid)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.character_reopening(text,uuid,jsonb,integer,uuid)', 'EXECUTE'),
  'only authenticated callers may use the facade');
select is((select count(*) from private.staff_capabilities where capability = 'characters.reopen' and staff_actor_id = '009f0000-0000-4000-8000-000000000003'), 0::bigint,
  'migration grants no real reopening rights');

select * from finish();
rollback;
