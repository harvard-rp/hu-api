begin;

create extension if not exists pgtap with schema extensions;
set local search_path to public, extensions;
select plan(53);

insert into auth.users (id) values
  ('70000000-0000-4000-8000-000000000001'),
  ('70000000-0000-4000-8000-000000000002');
insert into private.players (id, discord_id, auth_user_id) values
  ('70000000-0000-4000-8000-000000000001', '18446744073709551615', '70000000-0000-4000-8000-000000000001'),
  ('70000000-0000-4000-8000-000000000002', '100000000000000001', '70000000-0000-4000-8000-000000000002'),
  ('70000000-0000-4000-8000-000000000003', '100000000000000002', null);
insert into private.staff_actors (player_id) values
  ('70000000-0000-4000-8000-000000000001'),
  ('70000000-0000-4000-8000-000000000002');

select is(
  (select discord_id from private.players where id = '70000000-0000-4000-8000-000000000001'),
  '18446744073709551615', 'Discord snowflakes round-trip as text'
);
select throws_ok($$insert into private.players (discord_id) values ('18446744073709551615')$$,
  '23505', null, 'Discord snowflakes are unique');
select throws_ok($$insert into private.players (discord_id) values ('18446744073709551616')$$,
  '23514', null, 'Discord snowflakes fit the unsigned 64-bit range');
select throws_ok($$insert into private.players (discord_id) values ('01')$$,
  '23514', null, 'Discord snowflakes have one canonical text representation');
select throws_ok($$insert into private.players (discord_id, auth_user_id)
  values ('100000000000000010', '70000000-0000-4000-8000-000000000001')$$,
  '23505', null, 'a Supabase Auth account links to at most one player');
select throws_ok($$insert into private.players (discord_id, auth_user_id)
  values ('100000000000000010', '70000000-0000-4000-8000-000000000099')$$,
  '23503', null, 'a linked Supabase Auth account must exist');

select is((select count(*) from public.houses), 12::bigint, 'all 12 Houses are seeded');
select is((select count(*) from public.programs), 15::bigint, 'all 15 programs are seeded');
select is((select count(*) from public.clubs), 33::bigint, 'all 33 club entries are represented');
select is((select count(*) from public.clubs where slug = 'natation'), 1::bigint, 'swimming is seeded once');
select is((select is_active from public.clubs where slug = 'droit'), false, 'the law club is inactive');
select is((select member_capacity from public.clubs where slug = 'bde'), 10, 'the BDE has ten seats');
select is((select count(*) from public.clubs where member_capacity is not null), 1::bigint, 'only the BDE has a seeded cap');
select throws_ok($$update public.clubs set member_capacity = null where slug = 'bde'$$,
  '23514', null, 'the BDE capacity cannot be removed');

insert into private.characters (id, player_id, kind) values
  ('71000000-0000-4000-8000-000000000001', '70000000-0000-4000-8000-000000000001', 'student'),
  ('71000000-0000-4000-8000-000000000002', '70000000-0000-4000-8000-000000000002', 'citizen'),
  ('71000000-0000-4000-8000-000000000003', '70000000-0000-4000-8000-000000000001', 'teacher'),
  ('71000000-0000-4000-8000-000000000004', '70000000-0000-4000-8000-000000000003', 'staff_member');
insert into private.characters (player_id, kind)
  select '70000000-0000-4000-8000-000000000001', 'student' from generate_series(1, 5);
insert into public.character_profiles (character_id, first_name, last_name)
  values ('71000000-0000-4000-8000-000000000001', 'Test', 'Character');
insert into private.character_sheets (character_id, sexual_orientation, backstory)
  values ('71000000-0000-4000-8000-000000000002', 'Fictional field', 'Synthetic private sheet');

select throws_ok($$insert into private.characters (player_id, kind)
  values ('70000000-0000-4000-8000-000000000099', 'citizen')$$,
  '23503', null, 'a character owner must exist');
select throws_ok($$insert into private.characters (player_id, kind)
  values ('70000000-0000-4000-8000-000000000001', 'moderator')$$,
  '22P02', null, 'moderation is not a character type');
select throws_ok($$update private.characters set validation_status = 'pending'
  where id = '71000000-0000-4000-8000-000000000001'$$,
  '22P02', null, 'validation states come from the proposed set');
select throws_ok($$update private.characters set use_status = 'approved'
  where id = '71000000-0000-4000-8000-000000000001'$$,
  '22P02', null, 'validation states cannot be used as use statuses');
select throws_ok($$update private.characters set program_id = '72000000-0000-4000-8000-000000000099'
  where id = '71000000-0000-4000-8000-000000000001'$$,
  '23503', null, 'an assigned program must exist');
select throws_ok($$insert into private.character_sheets (character_id)
  values ('71000000-0000-4000-8000-000000000099')$$,
  '23503', null, 'a private sheet must belong to a character');

select lives_ok($$update private.characters set validation_status = 'submitted'
  where id = '71000000-0000-4000-8000-000000000001'$$, 'a draft can be submitted');
select throws_ok($$update private.characters set house_id = '10000000-0000-4000-8000-000000000001'
  where id = '71000000-0000-4000-8000-000000000001'$$,
  '23514', null, 'a House assignment requires a review');
select throws_ok($$insert into private.character_reviews (character_id, player_id, reviewer_id, decision)
  values ('71000000-0000-4000-8000-000000000001', '70000000-0000-4000-8000-000000000001',
    '70000000-0000-4000-8000-000000000001', 'approved')$$,
  '23514', null, 'a staff actor cannot approve their own character');
select throws_ok($$insert into private.character_reviews (character_id, player_id, reviewer_id, decision)
  values ('71000000-0000-4000-8000-000000000001', '70000000-0000-4000-8000-000000000002',
    '70000000-0000-4000-8000-000000000001', 'approved')$$,
  '23503', null, 'a reviewer cannot falsify a character owner');
select throws_ok($$insert into private.character_reviews (character_id, player_id, reviewer_id, decision)
  values ('71000000-0000-4000-8000-000000000001', '70000000-0000-4000-8000-000000000001',
    '70000000-0000-4000-8000-000000000003', 'approved')$$,
  '23503', null, 'playing a staff character gives no review authority');

insert into private.character_reviews (id, character_id, player_id, reviewer_id, decision, assigned_house_id) values
  ('72000000-0000-4000-8000-000000000001', '71000000-0000-4000-8000-000000000001',
   '70000000-0000-4000-8000-000000000001', '70000000-0000-4000-8000-000000000002',
   'changes_requested', '10000000-0000-4000-8000-000000000001'),
  ('72000000-0000-4000-8000-000000000002', '71000000-0000-4000-8000-000000000001',
   '70000000-0000-4000-8000-000000000001', '70000000-0000-4000-8000-000000000002', 'approved', null);

select throws_ok($$update private.characters set validation_status = 'approved',
  current_review_id = '72000000-0000-4000-8000-000000000002'
  where id = '71000000-0000-4000-8000-000000000001'$$,
  '23514', null, 'an approved student must have a House');
select throws_ok($$update private.characters set validation_status = 'rejected',
  current_review_id = '72000000-0000-4000-8000-000000000002'
  where id = '71000000-0000-4000-8000-000000000001'$$,
  '23503', null, 'a reviewed state must match its review outcome');
select throws_ok($$update private.characters set house_id = '10000000-0000-4000-8000-000000000002',
  house_review_id = '72000000-0000-4000-8000-000000000001'
  where id = '71000000-0000-4000-8000-000000000001'$$,
  '23503', null, 'the House must match the review record');
select lives_ok($$update private.characters set validation_status = 'approved',
  current_review_id = '72000000-0000-4000-8000-000000000002',
  house_id = '10000000-0000-4000-8000-000000000001',
  house_review_id = '72000000-0000-4000-8000-000000000001'
  where id = '71000000-0000-4000-8000-000000000001'$$,
  'a subsequent approval can retain a recorded House assignment');
select lives_ok($$update private.characters set use_status = 'suspended'
  where id = '71000000-0000-4000-8000-000000000001'$$, 'suspension is independent of validation');
select is((select validation_status::text from private.characters
  where id = '71000000-0000-4000-8000-000000000001'), 'approved', 'suspension preserves validation');
select lives_ok($$update private.characters set use_status = 'active'
  where id = '71000000-0000-4000-8000-000000000001'$$, 'a character can be reactivated');

select is((select allowed_slots from private.player_slot_capacity
  where player_id = '70000000-0000-4000-8000-000000000001'), 5::bigint, 'base capacity is five');
select throws_ok($$insert into private.boost_confirmations (player_id, confirmed_active_boosts, confirmed_by, reason)
  values ('70000000-0000-4000-8000-000000000001', -1,
    '70000000-0000-4000-8000-000000000002', 'Test negative count')$$,
  '23514', null, 'a confirmed active boost count cannot be negative');
insert into private.boost_confirmations (player_id, confirmed_active_boosts, confirmed_by, reason)
  values ('70000000-0000-4000-8000-000000000001', 3, '70000000-0000-4000-8000-000000000002', 'Test confirmed boosts');
select is((select allowed_slots from private.player_slot_capacity
  where player_id = '70000000-0000-4000-8000-000000000001'), 8::bigint, 'every active confirmed boost adds one slot');
insert into private.boost_confirmations (player_id, confirmed_active_boosts, confirmed_by, reason) values
  ('70000000-0000-4000-8000-000000000001', 0, '70000000-0000-4000-8000-000000000002', 'Test boost ended'),
  ('70000000-0000-4000-8000-000000000001', 1, '70000000-0000-4000-8000-000000000002', 'Test boost renewed');
select is((select allowed_slots from private.player_slot_capacity
  where player_id = '70000000-0000-4000-8000-000000000001'), 6::bigint, 'renewal does not leave a permanent bonus');
select is((select count(*) from private.characters
  where player_id = '70000000-0000-4000-8000-000000000001'), 7::bigint, 'a loss of capacity preserves every character');
select is((select count(*) from private.characters
  where player_id = '70000000-0000-4000-8000-000000000001' and use_status = 'suspended'),
  0::bigint, 'a loss of capacity does not automatically suspend characters');

insert into private.club_memberships (character_id, club_id, character_slot)
  select '71000000-0000-4000-8000-000000000001', id, case slug when 'boxe' then 1 else 2 end
  from public.clubs where slug in ('boxe', 'natation');
select throws_ok($$insert into private.club_memberships (character_id, club_id, character_slot)
  values ('71000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000004', 3)$$,
  '23514', null, 'a third active character slot is outside the domain');
select throws_ok($$insert into private.club_memberships (character_id, club_id, character_slot)
  values ('71000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000004', 2)$$,
  '23505', null, 'a character cannot reuse an occupied club slot');
update private.club_memberships set status = 'inactive', character_slot = null
  where character_id = '71000000-0000-4000-8000-000000000001'
  and club_id = '30000000-0000-4000-8000-000000000002';
select throws_ok($$insert into private.club_memberships (character_id, club_id, character_slot)
  values ('71000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000002', 1)$$,
  '23505', null, 'an inactive relationship is reactivated instead of duplicated');
select lives_ok($$insert into private.club_memberships (character_id, club_id, character_slot)
  values ('71000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000004', 1)$$,
  'leaving a club releases the character slot');

with roster as (
  insert into private.characters (player_id, kind)
    select '70000000-0000-4000-8000-000000000002', 'student' from generate_series(1, 10)
    returning id
)
insert into private.club_memberships (character_id, club_id, club_capacity_key, character_slot, club_seat)
  select id, '30000000-0000-4000-8000-000000000001', 10, 1, row_number() over (order by id) from roster;
select is((select count(*) from private.club_memberships
  where club_id = '30000000-0000-4000-8000-000000000001' and status = 'active'),
  10::bigint, 'all ten BDE seats may be occupied');
select throws_ok($$insert into private.club_memberships (character_id, club_id, club_capacity_key, character_slot, club_seat)
  values ('71000000-0000-4000-8000-000000000002', '30000000-0000-4000-8000-000000000001', 10, 1, 11)$$,
  '23514', null, 'an eleventh BDE seat is outside the domain');
select throws_ok($$insert into private.club_memberships (character_id, club_id, club_capacity_key, character_slot, club_seat)
  values ('71000000-0000-4000-8000-000000000002', '30000000-0000-4000-8000-000000000001', 10, 1, 10)$$,
  '23505', null, 'an occupied BDE seat cannot be reused');
select throws_ok($$insert into private.club_memberships (character_id, club_id, character_slot)
  values ('71000000-0000-4000-8000-000000000002', '30000000-0000-4000-8000-000000000001', 1)$$,
  '23503', null, 'a membership cannot forge an uncapped version of the BDE');

-- Change roles in a subtransaction so TAP assertions still run as the test operator.
create function pg_temp.statement_status(role_name text, statement text) returns text
language plpgsql as $$
begin
  execute format('set local role %I', role_name);
  execute statement;
  reset role;
  return '00000';
exception when others then
  return sqlstate;
end;
$$;

set local request.jwt.claim.sub = '70000000-0000-4000-8000-000000000001';
select ok((select bool_and(relrowsecurity) and count(*) = 11
  from pg_class where oid in (
    'private.players'::regclass, 'private.staff_actors'::regclass, 'private.boost_confirmations'::regclass,
    'private.characters'::regclass, 'private.character_sheets'::regclass, 'private.character_reviews'::regclass,
    'private.club_memberships'::regclass, 'public.character_profiles'::regclass,
    'public.clubs'::regclass, 'public.houses'::regclass, 'public.programs'::regclass
  )), 'all eleven domain tables have RLS');
select is(pg_temp.statement_status('anon', 'select * from private.players'), '42501', 'anonymous identities are denied');
select is(pg_temp.statement_status('anon', 'select * from public.houses'), '42501', 'anonymous catalogs are closed');
select is(pg_temp.statement_status('authenticated', 'select * from public.character_profiles'), '42501', 'authenticated profile reads are denied');
select is(pg_temp.statement_status('authenticated', $$select * from private.character_sheets
  where character_id = '71000000-0000-4000-8000-000000000002'$$),
  '42501', 'a player cannot read the private sheet of another player');
select is(pg_temp.statement_status('authenticated', $$update private.characters set validation_status = 'approved'$$),
  '42501', 'authenticated writes cannot approve a character');
select is(pg_temp.statement_status('authenticated', $$update public.clubs set name = 'Synthetic'$$),
  '42501', 'authenticated writes cannot edit the catalogs');

select * from finish();
rollback;
