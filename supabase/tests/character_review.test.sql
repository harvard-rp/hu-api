begin;
create extension if not exists pgtap with schema extensions;
set local search_path to public, extensions;
select plan(67);

create function pg_temp.review_id(prefix text, n integer) returns uuid language sql immutable as $$
  select (prefix || '090000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid
$$;
insert into auth.users (id, is_anonymous)
select pg_temp.review_id('aa', n), n = 5 from generate_series(1, 5) n;
insert into auth.sessions (id, user_id)
select pg_temp.review_id('bb', n), pg_temp.review_id('aa', n) from generate_series(1, 5) n;
insert into private.players (id, auth_user_id, discord_id)
select pg_temp.review_id('cc', n), pg_temp.review_id('aa', n), (963000000000000000 + n)::text
from generate_series(1, 3) n;
insert into private.staff_actors (player_id) values (pg_temp.review_id('cc', 1));
insert into private.staff_capabilities (staff_actor_id, capability)
values (pg_temp.review_id('cc', 1), 'characters.review');

insert into private.characters (id, player_id, kind, validation_status, use_status, program_id)
select pg_temp.review_id('dd', n), pg_temp.review_id('cc', case when n = 1 then 1 else 2 end),
  case when n in (3, 4) then 'student'::private.character_kind else 'teacher' end,
  case when n = 2 then 'draft'::private.validation_status else 'submitted' end,
  case when n = 3 then 'suspended'::private.character_use_status else 'active' end,
  (select id from public.programs order by slug limit 1)
from generate_series(1, 7) n;
insert into public.character_profiles (character_id, first_name, last_name)
select pg_temp.review_id('dd', n), 'Fictional', 'Example' from generate_series(1, 7) n;
insert into private.character_sheets (character_id, personality, physical_description, face_claim, backstory)
select pg_temp.review_id('dd', n), 'Curious', 'Fictional appearance', 'Fictional art', 'Synthetic private narrative'
from generate_series(1, 7) n;
insert into public.houses (id, name, slug, is_active)
values (pg_temp.review_id('ee', 1), 'Synthetic inactive House', 'synthetic-review-fixture', false);

create function pg_temp.review_claims(person integer) returns jsonb language sql stable as $$
  select jsonb_build_object('sub', pg_temp.review_id('aa', person), 'session_id', pg_temp.review_id('bb', person),
    'role', 'authenticated', 'aud', 'authenticated', 'is_anonymous', false,
    'exp', extract(epoch from now() + interval '5 minutes'),
    'user_metadata', '{"capabilities":["characters.review"],"role":"staff","discord_role":"staff"}'::jsonb)
$$;
create function pg_temp.staff_call(op text, target integer default null, payload jsonb default null,
  person integer default 1, size integer default null, cursor uuid default null) returns jsonb
language plpgsql security invoker as $$
declare result jsonb;
begin
  perform set_config('request.jwt.claims', pg_temp.review_claims(person)::text, true);
  set local role authenticated;
  select public.staff_character_reviews(op, pg_temp.review_id('dd', target), size, cursor, payload) into result;
  reset role;
  return result;
end;
$$;
create function pg_temp.owner_call(target integer, person integer default 2) returns jsonb
language plpgsql security invoker as $$
declare result jsonb;
begin
  perform set_config('request.jwt.claims', pg_temp.review_claims(person)::text, true);
  set local role authenticated;
  select public.player_character_review_history(pg_temp.review_id('dd', target)) into result;
  reset role;
  return result;
end;
$$;
create function pg_temp.decision(target integer, decision text, fields jsonb default '{}') returns jsonb
language sql stable as $$
  select jsonb_build_object('decision', decision, 'expectedRevision', revision) || fields
  from private.characters where id = pg_temp.review_id('dd', target)
$$;
create temp table active_review_houses as
select id, row_number() over (order by slug) as n from public.houses where is_active order by slug limit 2;

select is(pg_temp.staff_call('queue', person => 2)->>'status', 'forbidden', 'claims cannot grant review to a teacher or player');
select is(pg_temp.staff_call('queue', person => 4)->>'status', 'player_link_required', 'unlinked accounts get no review access');
select is(pg_temp.staff_call('queue', person => 5)->>'status', 'unauthenticated', 'an anonymous Auth user cannot review');
select is(pg_temp.staff_call('queue', size => 0)->>'status', 'invalid_request', 'pagination lower bound');
select is(pg_temp.staff_call('queue', size => 51)->>'status', 'invalid_request', 'pagination upper bound');
select is(pg_temp.staff_call('detail', 3, size => 2)->>'status', 'invalid_request', 'detail does not accept queue parameters');
select is(jsonb_array_length(pg_temp.staff_call('queue', size => 2)#>'{data,items}'), 2, 'the queue is bounded');
select is(pg_temp.staff_call('queue', size => 2)#>>'{data,items,0,id}', pg_temp.review_id('dd', 3)::text,
  'the queue omits drafts and the reviewer’s own submitted sheet');
select is(pg_temp.staff_call('queue', size => 2)#>>'{data,nextCursor}', pg_temp.review_id('dd', 4)::text, 'keyset continuation');
select is(pg_temp.staff_call('queue', size => 3, cursor => pg_temp.review_id('dd', 4))#>'{data,nextCursor}', 'null'::jsonb,
  'the final page has no continuation');
select is(pg_temp.staff_call('queue', cursor => pg_temp.review_id('dd', 4))#>>'{data,items,0,id}',
  pg_temp.review_id('dd', 5)::text, 'cursor advances to the next sheet');
select ok(not (pg_temp.staff_call('queue')#>'{data,items,0}' ? 'backstory'), 'queue never returns a narrative');
select is(pg_temp.staff_call('detail', 3)#>>'{data,backstory}', 'Synthetic private narrative', 'authorized staff can read submitted detail');
select is(pg_temp.staff_call('detail', 2)->>'status', 'not_found', 'staff cannot read drafts');
select is(pg_temp.staff_call('detail', 1)->>'status', 'not_found', 'staff route cannot read its actor’s own sheet');
select is(pg_temp.staff_call('history', 2)->>'status', 'not_found', 'staff history does not reveal a draft');
select is(pg_temp.staff_call('history', 1)->>'status', 'not_found', 'staff history excludes the actor’s own sheet');
select is(pg_temp.staff_call('decide', 1, pg_temp.decision(1, 'approved'))->>'status', 'not_found', 'self-review is forbidden');
select is(pg_temp.staff_call('decide', 2, pg_temp.decision(2, 'approved'))->>'status', 'not_found', 'a draft cannot be reviewed');
select is(pg_temp.staff_call('decide', 3, pg_temp.decision(3, 'approved'))->>'status', 'house_required', 'student approval needs a House');
select is(pg_temp.staff_call('decide', 3, pg_temp.decision(3, 'approved',
    jsonb_build_object('houseId', pg_temp.review_id('ee', 1))))->>'status',
  'invalid_house', 'a new House must be active');
select is(pg_temp.staff_call('decide', 3, pg_temp.decision(3, 'approved',
    jsonb_build_object('houseId', pg_temp.review_id('ee', 2))))->>'status',
  'invalid_house', 'a new House must exist');
select is(pg_temp.staff_call('decide', 5, pg_temp.decision(5, 'approved',
    jsonb_build_object('houseId', (select id from active_review_houses where n = 1))))->>'status',
  'invalid_house', 'a House cannot be assigned to a teacher');
select is(pg_temp.staff_call('decide', 4, pg_temp.decision(4, 'rejected'))->>'status', 'comment_required', 'rejection needs a comment');
select is(pg_temp.staff_call('decide', 4, pg_temp.decision(4, 'changes_requested'))->>'status',
  'comment_required', 'a correction request needs a comment');
select is(pg_temp.staff_call('decide', 4, pg_temp.decision(4, 'approved', '{"comment":" \n\t "}'::jsonb))->>'status',
  'invalid_request', 'a supplied comment must be nonblank');
select is(pg_temp.staff_call('decide', 4, pg_temp.decision(4, 'approved', jsonb_build_object('comment', repeat('x', 2001))))->>'status',
  'invalid_request', 'comment size is bounded');
select is(pg_temp.staff_call('decide', 4, pg_temp.decision(4, 'approved', '{"reviewerId":"spoof","note":"private"}'))->>'status',
  'invalid_request', 'unknown fields and reviewer selection are refused');
select is(pg_temp.staff_call('decide', 5, pg_temp.decision(5, 'approved',
    jsonb_build_object('expectedRevision', gen_random_uuid())))->>'status', 'revision_conflict', 'an outdated revision is rejected');
select is((select count(*) from private.character_reviews), 0::bigint, 'refused decisions append nothing');

create temp table approved_review as
select pg_temp.staff_call('decide', 3, pg_temp.decision(3, 'approved',
  jsonb_build_object('houseId', (select id from active_review_houses where n = 1)))) as payload;
select is((select payload->>'status' from approved_review), 'ok', 'approves a student and assigns a House');
select is((select payload#>>'{data,revision}' from approved_review),
  (select revision::text from private.characters where id = pg_temp.review_id('dd', 3)), 'returns the new sheet revision');
select is((select use_status::text from private.characters where id = pg_temp.review_id('dd', 3)),
  'suspended', 'approval leaves the use status unchanged');
select ok((select c.current_review_id = r.id and c.house_review_id = r.id and r.reviewer_id = pg_temp.review_id('cc', 1)
  from private.characters c join private.character_reviews r on c.id = r.character_id where c.id = pg_temp.review_id('dd', 3)),
  'the decision and House reference the same review and the verified actor');
select is(pg_temp.staff_call('detail', 3)->>'status', 'not_found', 'approved sheet content is closed to staff');
select is(pg_temp.staff_call('history', 3)#>>'{data,0,decision}', 'approved', 'staff can read a previous decision');
select is(pg_temp.staff_call('decide', 3, pg_temp.decision(3, 'rejected', '{"comment":"Fixture"}'))->>'status',
  'not_submitted', 'an already decided sheet cannot receive another decision');
select is(pg_temp.owner_call(3)#>'{data,0}',
  (select payload#>'{data,review}' from approved_review), 'owner sees exactly the player-facing decision fields');
select is(pg_temp.owner_call(3, 1)->>'status', 'not_found', 'staff capability does not widen the owner history route');
select is(pg_temp.owner_call(3, 3)->>'status', 'not_found', 'another owner cannot see a decision');
select is(pg_temp.staff_call('decide', 5, pg_temp.decision(5, 'approved'))->>'status', 'ok', 'a teacher can be approved without a House');

create temp table corrected_review as
select pg_temp.staff_call('decide', 4, pg_temp.decision(4, 'changes_requested',
  jsonb_build_object('houseId', (select id from active_review_houses where n = 2), 'comment', 'Clarify the fictional timeline.'))) as payload;
select is((select payload#>>'{data,review,decision}' from corrected_review), 'changes_requested', 'requests corrections with a House');
select is(pg_temp.owner_call(4)#>>'{data,0,comment}', 'Clarify the fictional timeline.', 'player receives the correction comment');
create function pg_temp.resubmit_for_review(target integer) returns jsonb language plpgsql security invoker as $$
declare result jsonb;
declare target_id uuid := pg_temp.review_id('dd', target);
declare current_revision uuid;
begin
  select revision into current_revision from private.characters where id = target_id;
  perform set_config('request.jwt.claims', pg_temp.review_claims(2)::text, true);
  set local role authenticated;
  select public.player_characters('submit', target_id, current_revision) into result;
  reset role;
  return result;
end;
$$;
select is(pg_temp.resubmit_for_review(4)->>'status', 'ok', 'HU-009A permits resubmission after corrections');
select is(pg_temp.owner_call(4)#>>'{data,0,decision}', 'changes_requested', 'resubmission preserves the visible decision');

update public.houses set is_active = false where id = (select id from active_review_houses where n = 2);
select is(pg_temp.staff_call('decide', 4, pg_temp.decision(4, 'approved'))#>>'{data,review,decision}',
  'approved', 'approval can preserve a valid historical House assignment');
select ok((select c.house_review_id <> c.current_review_id and c.house_id = (select id from active_review_houses where n = 2)
  from private.characters c where c.id = pg_temp.review_id('dd', 4)), 'preservation keeps the original House review reference');
select is(jsonb_array_length(pg_temp.owner_call(4)->'data'), 2, 'both decisions remain in chronological history');
select is(pg_temp.owner_call(4)#>'{data,1,assignedHouseId}', 'null'::jsonb, 'the later decision does not claim it assigned the House again');
select is(pg_temp.staff_call('decide', 6, pg_temp.decision(6, 'rejected', '{"comment":"Fictional example."}'))->>'status',
  'ok', 'rejection records a player comment');
select is(pg_temp.resubmit_for_review(6)->>'status', 'character_locked', 'a refused sheet cannot be resubmitted');

alter table private.characters add constraint review_fixture_fail_update
  check (id <> 'dd090000-0000-4000-8000-000000000007' or validation_status = 'submitted');
create temp table transaction_revision as select revision from private.characters where id = pg_temp.review_id('dd', 7);
select is(pg_temp.staff_call('decide', 7, pg_temp.decision(7, 'approved')),
  '{"status":"unavailable"}'::jsonb, 'a post-insert constraint failure is sanitized');
select is((select count(*) from private.character_reviews where character_id = pg_temp.review_id('dd', 7)),
  0::bigint, 'an update failure rolls back the inserted review');
select is((select revision from private.characters where id = pg_temp.review_id('dd', 7)),
  (select revision from transaction_revision), 'an update failure preserves the submitted revision');

select set_config('request.jwt.claims', pg_temp.review_claims(2)::text, true);
set local role authenticated;
select is((select x->>'canAccessCampus' from jsonb_array_elements(public.current_player_context()->'characters') x
  where x->>'id' = pg_temp.review_id('dd', 3)::text), 'false', 'an approved suspended sheet is ineligible for campus');
select is((select x->>'canAccessCampus' from jsonb_array_elements(public.current_player_context()->'characters') x
  where x->>'id' = pg_temp.review_id('dd', 5)::text), 'true', 'the context reflects active approval');
reset role;

delete from private.staff_capabilities where staff_actor_id = pg_temp.review_id('cc', 1);
select is(pg_temp.staff_call('queue')->>'status', 'forbidden', 'removing the capability revokes access for the same claims');
select is(pg_temp.staff_call('decide', 7, pg_temp.decision(7, 'approved'))->>'status', 'forbidden', 'revocation also blocks writes');
delete from auth.sessions where id = pg_temp.review_id('bb', 2);
select is(pg_temp.owner_call(3)->>'status', 'unauthenticated', 'revoked tokens cannot read owner history directly');
select ok(not has_schema_privilege('authenticated', 'character_review', 'USAGE')
  and not has_schema_privilege('authenticated', 'private', 'USAGE'), 'implementation schemas remain private');
select ok(not has_function_privilege('anon', 'public.staff_character_reviews(text,uuid,integer,uuid,jsonb)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.player_character_review_history(uuid)', 'EXECUTE'),
  'public RPCs have no implicit execute grants');
select ok(not has_any_column_privilege('authenticated', 'private.character_reviews', 'INSERT,SELECT,UPDATE')
  and not has_table_privilege('hu_character_review', 'private.character_reviews', 'UPDATE,DELETE'),
  'reviews are append-only through the dedicated boundary');
select ok(not has_column_privilege('hu_character_review', 'private.characters', 'use_status', 'UPDATE')
  and not has_any_column_privilege('hu_character_review', 'private.staff_capabilities', 'INSERT,UPDATE'),
  'staff reviewer cannot alter use state or grant capabilities');
select ok((select not rolcanlogin and not rolbypassrls and not rolsuper from pg_roles where rolname = 'hu_character_review'),
  'staff reviewer role cannot login or bypass row security');

-- The row-lock grant is not a route to catalog writes.
create function pg_temp.try_deactivate_house(target uuid) returns boolean
language plpgsql security invoker as $$
begin
  perform set_config('request.jwt.claims', pg_temp.review_claims(1)::text, true);
  set local role hu_character_review;
  update public.houses set is_active = false where id = target;
  reset role;
  return found;
exception when insufficient_privilege then
  return false;
end;
$$;
insert into private.staff_capabilities (staff_actor_id, capability)
values (pg_temp.review_id('cc', 1), 'characters.review');
select ok(not pg_temp.try_deactivate_house((select id from active_review_houses where n = 1)),
  'the reviewer role cannot deactivate a House despite the row-lock grant');
select ok((select is_active from public.houses where id = (select id from active_review_houses where n = 1)),
  'the House remains active');
select ok(not has_schema_privilege('hu_character_review', 'character_review', 'CREATE'),
  'the function owner cannot create arbitrary routines');

select * from finish();
rollback;
