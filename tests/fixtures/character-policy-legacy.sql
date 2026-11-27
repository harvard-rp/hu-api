-- Run only on a disposable database after the HU-009E migrations.
-- psql -X -v ON_ERROR_STOP=1 -f tests/fixtures/character-policy-legacy.sql
\set ON_ERROR_STOP on
begin;
create temporary table legacy_characters (
  id uuid primary key, review_id uuid not null, assigned_house_id uuid, house_review_id uuid,
  use_status private.character_use_status not null, validation_status private.validation_status not null,
  archived boolean not null, refusals integer not null
) on commit preserve rows;

insert into private.players (id, discord_id) values
  ('009f00bb-0000-4000-8000-000000000001', '990090000000009701'),
  ('009f00bb-0000-4000-8000-000000000002', '990090000000009702');
insert into private.staff_actors (player_id) values ('009f00bb-0000-4000-8000-000000000002');
do $$
declare
  owner_id uuid := '009f00bb-0000-4000-8000-000000000001';
  reviewer_id uuid := '009f00bb-0000-4000-8000-000000000002';
  house uuid := (select id from public.houses order by slug limit 1);
  target_id uuid;
  current_decision uuid;
  legacy_house_decision uuid;
  i integer;
  historical_refusals integer;
  state private.validation_status;
begin
  for i in 1..3 loop
    historical_refusals := case when i = 3 then 2 else 3 end;
    state := case when i = 1 then 'approved' else 'rejected' end;
    insert into private.characters (player_id, kind, use_status)
      values (owner_id, 'student', 'suspended') returning id into target_id;
    insert into public.character_profiles (character_id, first_name, last_name) values (target_id, 'Legacy', 'Fictional');
    insert into private.character_sheets (character_id, backstory) values (target_id, 'Synthetic historical data');
    insert into private.character_reviews (character_id, player_id, reviewer_id, decision, assigned_house_id)
      values (target_id, owner_id, reviewer_id, 'changes_requested', house) returning id into legacy_house_decision;
    for attempt in 1..historical_refusals loop
      insert into private.character_reviews (character_id, player_id, reviewer_id, decision, note)
        values (target_id, owner_id, reviewer_id, 'rejected', 'Synthetic decision') returning id into current_decision;
    end loop;
    if state = 'approved' then
      insert into private.character_reviews (character_id, player_id, reviewer_id, decision)
        values (target_id, owner_id, reviewer_id, 'approved') returning id into current_decision;
    end if;
    update private.characters set validation_status = state, current_review_id = current_decision,
      house_id = house, house_review_id = legacy_house_decision where id = target_id;
    insert into legacy_characters values (target_id, current_decision, house, legacy_house_decision,
      'suspended', state, i = 2, historical_refusals);
  end loop;
end $$;
commit;

begin;
\ir ../../supabase/migrations/20261127150000_character_reopen_capability.sql
commit;
begin;
\ir ../../supabase/migrations/20261127150001_character_policy.sql
commit;

do $$
begin
  if (select count(*) from legacy_characters) <> (select count(*) from private.characters c join legacy_characters l on l.id = c.id)
    or exists (
      select 1 from private.characters c join legacy_characters l on l.id = c.id
      join private.character_reviews r on r.id = l.review_id
      where (c.current_review_id, c.house_id, c.house_review_id, c.validation_status, c.use_status,
        c.refusal_count, c.archived_at is not null, c.sheet_mode::text, r.archived_character)
        is distinct from (l.review_id, l.assigned_house_id, l.house_review_id, l.validation_status, l.use_status,
        l.refusals, l.archived, 'inline', l.archived)
        or (l.archived and c.archived_at is distinct from r.reviewed_at)
    ) or (select count(*) from private.character_reviews r join legacy_characters l on l.id = r.character_id) <> 12
    or (select count(*) from private.character_sheets s join legacy_characters l on l.id = s.character_id
      where s.backstory = 'Synthetic historical data') <> 3
    or exists (select 1 from private.staff_capabilities where capability = 'characters.reopen')
  then raise exception 'Legacy character policy reconciliation failed'; end if;
end $$;
select 'Verified approved grandfathering, threshold archival, suspension, House references, sheet contents and 12 prior reviews.';
