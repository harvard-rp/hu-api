begin;
create extension if not exists pgtap with schema extensions;
set local search_path to public, extensions;
select plan(67);

insert into auth.users (id, is_anonymous, banned_until) values
  ('a9000000-0000-4000-8000-000000000001', false, null),
  ('a9000000-0000-4000-8000-000000000002', false, null),
  ('a9000000-0000-4000-8000-000000000003', false, null),
  ('a9000000-0000-4000-8000-000000000004', true, null),
  ('a9000000-0000-4000-8000-000000000005', false, now() + interval '1 day');
insert into auth.sessions (id, user_id)
select replace(id::text, 'a900', 'b900')::uuid, id from auth.users where id::text like 'a900%';

insert into private.players (id, discord_id, auth_user_id) values
  ('c9000000-0000-4000-8000-000000000001', '900000000000000001', 'a9000000-0000-4000-8000-000000000001'),
  ('c9000000-0000-4000-8000-000000000002', '900000000000000002', 'a9000000-0000-4000-8000-000000000002');
insert into private.staff_actors (player_id) values ('c9000000-0000-4000-8000-000000000002');

create function pg_temp.lifecycle_claims(person integer) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'sub', 'a9000000-0000-4000-8000-00000000000' || person,
    'session_id', 'b9000000-0000-4000-8000-00000000000' || person,
    'role', 'authenticated', 'aud', 'authenticated', 'is_anonymous', false,
    'exp', extract(epoch from now() + interval '5 minutes'),
    'user_metadata', '{"playerId":"c9000000-0000-4000-8000-000000000002","capabilities":["characters.review"]}'::jsonb)
$$;

create function pg_temp.character_call(
  operation text, target_id uuid default null, expected_revision uuid default null,
  fields jsonb default null, claims jsonb default pg_temp.lifecycle_claims(1)
) returns jsonb
language plpgsql security invoker as $$
declare result jsonb;
begin
  perform set_config('request.jwt.claims', claims::text, true);
  set local role authenticated;
  select public.player_characters(operation, target_id, expected_revision, fields) into result;
  reset role;
  return result;
end;
$$;

select is(pg_temp.character_call('capacity')->'data', '{"total":5,"used":0,"available":5}'::jsonb,
  'new players have five base slots');
select is(pg_temp.character_call('list')->'data', '[]'::jsonb, 'empty character list');
select is(pg_temp.character_call('list', claims => pg_temp.lifecycle_claims(3))->>'status',
  'player_link_required', 'unlinked accounts cannot read');
select is(pg_temp.character_call('create', fields => '{"kind":"citizen"}', claims => pg_temp.lifecycle_claims(4))->>'status',
  'unauthenticated', 'an anonymous Auth row cannot write even with a permanent claim');
select is(pg_temp.character_call('list', claims => pg_temp.lifecycle_claims(5))->>'status',
  'unauthenticated', 'a banned user cannot read');
select is(pg_temp.character_call('list', claims => pg_temp.lifecycle_claims(1) || '{"exp":1}')->>'status',
  'unauthenticated', 'a still-present session cannot extend access beyond JWT expiry');
select is(pg_temp.character_call('list', claims => pg_temp.lifecycle_claims(1)
  || jsonb_build_object('session_id', pg_temp.lifecycle_claims(2)->>'session_id'))->>'status',
  'unauthenticated', 'a session belonging to another user cannot be used');
select is(pg_temp.character_call('list', claims => pg_temp.lifecycle_claims(1) || '{"is_anonymous":true}')->>'status',
  'unauthenticated', 'anonymous claims cannot use the RPC');

select is(pg_temp.character_call('create', fields => '{"kind":"student","houseId":null}')->>'status',
  'invalid_request', 'a player cannot set a House even to null');
select is(pg_temp.character_call('create', fields => '{"kind":"student","playerId":"c9000000-0000-4000-8000-000000000002"}')->>'status',
  'invalid_request', 'a payload cannot choose its owner');
select is(pg_temp.character_call('create', fields => '{"kind":"staff_member","capabilities":["characters.review"]}')->>'status',
  'invalid_request', 'RP staff type grants no privilege');
select is(pg_temp.character_call('create', fields => '{"kind":"student","birthDate":"2025-02-29"}')->>'status',
  'invalid_request', 'reject an impossible date');
select is(pg_temp.character_call('create', fields => '{"kind":"student","age":"20"}')->>'status',
  'invalid_request', 'reject wrongly typed age');
select is(pg_temp.character_call('create', fields => '{"kind":"student","programId":"90000000-0000-4000-8000-000000000000"}')->>'status',
  'invalid_program', 'reject a program not in the active catalog');
select is(pg_temp.character_call('create', fields => '{"kind":"citizen","isScholarshipHolder":false}')->>'status',
  'invalid_request', 'scholarship is applicable to a student only');

create temp table lifecycle_result (result jsonb);
insert into lifecycle_result values (pg_temp.character_call('create', fields => '{"kind":"student","firstName":"Fictional","age":21,"contentWarnings":["RP-only warning"]}'));
create temp view lifecycle_draft as
select (result#>>'{data,id}')::uuid as id, (result#>>'{data,revision}')::uuid as rev
from lifecycle_result;

select is((select result->>'status' from lifecycle_result), 'ok', 'create a partial draft');
select is((select result#>>'{data,validationStatus}' from lifecycle_result), 'draft', 'draft starts unvalidated');
select is((select result#>>'{data,useStatus}' from lifecycle_result), 'active', 'draft use state is independent');
select is((select p.first_name from public.character_profiles p join lifecycle_draft d on p.character_id = d.id),
  'Fictional', 'the profile is stored under the created character');
select is((select s.age from private.character_sheets s join lifecycle_draft d on s.character_id = d.id),
  21::smallint, 'the sheet is stored in the same transaction');
select is(pg_temp.character_call('detail', (select id from lifecycle_draft)), (select result from lifecycle_result),
  'owned detail returns the stored sheet');
select is(pg_temp.character_call('list')#>>'{data,0,firstName}', 'Fictional',
  'owned list includes profile summary');
select ok(not (pg_temp.character_call('list')#>'{data,0}' ? 'contentWarnings'),
  'list does not project the private narrative');
select is(pg_temp.character_call('list', claims => pg_temp.lifecycle_claims(2))->'data', '[]'::jsonb,
  'the reviewer fixture cannot list another player’s sheets');
select is(pg_temp.character_call('detail', (select id from lifecycle_draft), claims => pg_temp.lifecycle_claims(2))->>'status',
  'not_found', 'another player cannot read a sheet');
select is(pg_temp.character_call('edit', d.id, d.rev, '{"firstName":"Intruder"}', pg_temp.lifecycle_claims(2))->>'status',
  'not_found', 'another player cannot edit a sheet') from lifecycle_draft d;
select is(pg_temp.character_call('submit', d.id, d.rev, claims => pg_temp.lifecycle_claims(2))->>'status',
  'not_found', 'another player cannot submit a sheet') from lifecycle_draft d;

select is(pg_temp.character_call('submit', d.id, d.rev)->>'status',
  'incomplete', 'an incomplete draft cannot be submitted') from lifecycle_draft d;
select is(pg_temp.character_call('edit', d.id, d.rev, '{"validationStatus":"approved"}')->>'status',
  'invalid_request', 'a generic edit cannot exercise staff powers') from lifecycle_draft d;
select is(pg_temp.character_call('detail', d.id)#>>'{data,revision}', d.rev::text,
  'failed operations leave the revision unchanged') from lifecycle_draft d;

create temp table previous_revision as select rev from lifecycle_draft;
update lifecycle_result set result = (
  select pg_temp.character_call('edit', d.id, d.rev, jsonb_build_object(
    'lastName', 'Example', 'personality', 'Curious', 'physicalDescription', 'Tall',
    'faceClaim', 'Fictional illustration', 'backstory', 'A synthetic past', 'age', null,
    'programId', (select id from public.programs order by slug limit 1)))
  from lifecycle_draft d);
select is((select result->>'status' from lifecycle_result), 'ok', 'edit an incomplete draft');
select is((select result#>>'{data,firstName}' from lifecycle_result), 'Fictional', 'omitted fields survive');
select is((select result#>'{data,age}' from lifecycle_result), 'null'::jsonb, 'explicit null clears a field');
select is(pg_temp.character_call('edit', d.id, (select rev from previous_revision), '{"firstName":"Stale"}')->>'status',
  'revision_conflict', 'a stale edit cannot overwrite the latest update') from lifecycle_draft d;
select is(pg_temp.character_call('submit', d.id, (select rev from previous_revision))->>'status',
  'revision_conflict', 'a stale client cannot submit unseen changes') from lifecycle_draft d;

update lifecycle_result set result = (select pg_temp.character_call('submit', d.id, d.rev) from lifecycle_draft d);
select is((select result#>>'{data,validationStatus}' from lifecycle_result), 'submitted', 'submit a complete student');
select is((select result#>'{data,houseId}' from lifecycle_result), 'null'::jsonb, 'submission does not assign a House');
select is(pg_temp.character_call('edit', d.id, d.rev, '{"firstName":"Locked"}')->>'status',
  'character_locked', 'a submitted sheet cannot be changed') from lifecycle_draft d;

insert into private.character_reviews (id, character_id, player_id, reviewer_id, decision, assigned_house_id)
select 'e9000000-0000-4000-8000-000000000001', d.id, 'c9000000-0000-4000-8000-000000000001',
  'c9000000-0000-4000-8000-000000000002', 'changes_requested', (select id from public.houses order by slug limit 1)
from lifecycle_draft d;
update private.characters c set validation_status = 'changes_requested', current_review_id = r.id,
  house_review_id = r.id, house_id = r.assigned_house_id, use_status = 'suspended'
from private.character_reviews r where c.id = r.character_id;
select isnt(pg_temp.character_call('detail', d.id)#>>'{data,revision}', d.rev::text,
  'a trusted character-row update also invalidates earlier revisions') from lifecycle_draft d;
update lifecycle_result set result = (select pg_temp.character_call('detail', id) from lifecycle_draft);
update lifecycle_result set result = (select pg_temp.character_call('edit', id, rev, '{"backstory":"A corrected synthetic past"}') from lifecycle_draft);
select is((select result->>'status' from lifecycle_result), 'ok', 'changes_requested sheets can be edited');
update lifecycle_result set result = (select pg_temp.character_call('submit', id, rev) from lifecycle_draft);
select is((select result#>>'{data,validationStatus}' from lifecycle_result), 'submitted', 'resubmit a corrected sheet');
select is((select result#>>'{data,useStatus}' from lifecycle_result), 'suspended', 'resubmission preserves suspension');
select ok((select house_id is not null and current_review_id is null from private.characters c join lifecycle_draft d on c.id = d.id),
  'resubmission preserves the staff-assigned House and releases the previous current-review pointer');
select is((select count(*) from private.character_reviews), 1::bigint, 'review history is retained');

do $$
declare decision_type private.validation_status;
begin
  foreach decision_type in array array['approved', 'rejected']::private.validation_status[] loop
    insert into private.character_reviews (character_id, player_id, reviewer_id, decision)
    select d.id, c.player_id, 'c9000000-0000-4000-8000-000000000002', decision_type
    from lifecycle_draft d join private.characters c on c.id = d.id;
  end loop;
end;
$$;
update private.characters c set validation_status = r.decision, current_review_id = r.id
  from private.character_reviews r where c.id = r.character_id and r.decision = 'approved';
select is(pg_temp.character_call('edit', d.id, d.rev, '{"nickname":"Locked"}')->>'status',
  'character_locked', 'approved sheets cannot be edited') from lifecycle_draft d;
update private.characters c set validation_status = r.decision, current_review_id = r.id
  from private.character_reviews r where c.id = r.character_id and r.decision = 'rejected';
select is(pg_temp.character_call('submit', d.id, d.rev)->>'status',
  'character_locked', 'rejected sheets cannot be submitted again') from lifecycle_draft d;

alter table private.character_sheets add constraint fixture_fail_sheet_write
  check (backstory <> 'Synthetic constraint failure');
select is(pg_temp.character_call('create', fields =>
  '{"kind":"citizen","firstName":"Atomic fixture","backstory":"Synthetic constraint failure"}'),
  '{"status":"unavailable"}'::jsonb, 'a sheet constraint failure aborts the write without exposing row details');
select is((select count(*) from private.characters), 1::bigint, 'a failed sheet write leaves no character row');
select is((select count(*) from public.character_profiles), 1::bigint, 'a failed sheet write leaves no profile row');

insert into private.boost_confirmations (player_id, confirmed_active_boosts, confirmed_by, reason)
values ('c9000000-0000-4000-8000-000000000001', 2,'c9000000-0000-4000-8000-000000000002','Test-only allowance');
select is(pg_temp.character_call('capacity')->'data', '{"total":7,"used":1,"available":6}'::jsonb,
  'the latest confirmed boost count extends capacity');
select is((select count(*) from generate_series(1,6) n
  where pg_temp.character_call('create', fields => '{"kind":"citizen"}')->>'status' = 'ok'),
  6::bigint, 'remaining slots accept drafts');
select is(pg_temp.character_call('create', fields => '{"kind":"teacher"}')->>'status',
  'capacity_reached', 'creating at full capacity fails');
insert into private.boost_confirmations (player_id, confirmed_active_boosts, confirmed_by, reason)
values ('c9000000-0000-4000-8000-000000000001', 0,'c9000000-0000-4000-8000-000000000002','Test-only decrease');
select is(pg_temp.character_call('capacity')->'data', '{"total":5,"used":7,"available":0}'::jsonb,
  'a reduction preserves all sheets and clamps free slots at zero');
select is(jsonb_array_length(pg_temp.character_call('list')->'data'), 7, 'all sheets remain readable while over capacity');
select is(pg_temp.character_call('create', fields => '{"kind":"citizen"}')->>'status',
  'capacity_reached', 'over-capacity players cannot create another draft');

set local role authenticated;
select is((select public.player_character_catalog('clubs')->>'status'), 'ok', 'linked players can read active catalogs');
select ok(not exists (select 1 from jsonb_array_elements(public.player_character_catalog('clubs')->'data') x
  where x->>'slug' = 'droit'), 'inactive club is omitted');
reset role;

select ok(not has_schema_privilege('authenticated', 'private', 'USAGE'), 'private schema remains closed');
select ok(not has_column_privilege('authenticated', 'public.character_profiles', 'first_name', 'SELECT'),
  'client roles have no generic access to profiles');
select ok(not has_column_privilege('authenticated', 'private.character_sheets', 'backstory', 'UPDATE'),
  'client roles have no generic write grants');
select ok(not has_column_privilege('hu_character_lifecycle', 'private.characters', 'house_id', 'UPDATE')
  and not has_column_privilege('hu_character_lifecycle', 'private.characters', 'use_status', 'UPDATE')
  and not has_column_privilege('hu_character_lifecycle', 'private.staff_capabilities', 'capability', 'INSERT'),
  'the dedicated owner cannot assign Houses, suspend characters or grant capabilities');
select ok(not has_function_privilege('anon', 'public.player_characters(text,uuid,uuid,jsonb)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.player_character_catalog(text)', 'EXECUTE'),
  'facades are reserved to authenticated clients');
select ok(not has_function_privilege('authenticated', 'character_lifecycle.save_sheet(uuid,jsonb)', 'EXECUTE'),
  'the generic persistence helper cannot be called as a client');
select ok((select not rolcanlogin and not rolsuper and not rolbypassrls
  from pg_roles where rolname = 'hu_character_lifecycle'), 'the dedicated owner has no login or RLS bypass');
select ok((select not prosecdef from pg_proc where oid = 'public.player_characters(text,uuid,uuid,jsonb)'::regprocedure),
  'the exposed facade runs as invoker');

delete from auth.sessions where id = 'b9000000-0000-4000-8000-000000000001';
select is(pg_temp.character_call('list')->>'status', 'unauthenticated', 'the direct read fails after session revocation');
select is(pg_temp.character_call('create', fields => '{"kind":"citizen"}')->>'status',
  'unauthenticated', 'the direct write fails after session revocation');
select * from finish();
rollback;
