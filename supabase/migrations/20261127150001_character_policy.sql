-- Inventory with the read-only checklist in docs/CHARACTER_POLICY_MIGRATION.md.
-- Backfill from the append-only history. A legacy approval or in-progress sheet
-- keeps its disposition; an existing rejected sheet at threshold is archived.
alter table private.characters
  add column refusal_count integer not null default 0 check (refusal_count >= 0),
  add column archived_at timestamptz,
  add constraint characters_archive_state check (
    archived_at is null or (validation_status = 'rejected' and refusal_count >= 3)
  );
with counts as (
  select character_id, count(*)::integer as total
  from private.character_reviews where decision = 'rejected' group by character_id
)
update private.characters c set
  refusal_count = counts.total,
  archived_at = case when c.validation_status = 'rejected' and counts.total >= 3
    then (select r.reviewed_at from private.character_reviews r where r.id = c.current_review_id) end
from counts where c.id = counts.character_id;

create index characters_occupied_slots_idx on private.characters (player_id) where archived_at is null;
create index characters_archive_idx on private.characters (id) where archived_at is not null;

-- A strict lexical allowlist shared by PostgreSQL and the HTTP boundary. Only
-- viewing paths are admitted. Optional safe query/fragment content grants no
-- access to any other host. Nothing dereferences the URL.
create function character_lifecycle.valid_external_url(link text) returns boolean
language sql immutable security invoker set search_path = ''
begin atomic
  select length(link) <= 2048 and link collate "C" ~
    '^https://(www[.]canva[.]com/design/[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)?/view|docs[.]google[.]com/document/(u/[0-9]+/)?(d/[A-Za-z0-9_-]+/(edit|view|preview)|d/e/[A-Za-z0-9_-]+/pub)|sites[.]google[.]com/view/[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)*/?)([?][A-Za-z0-9._~!$&()*+,;=:@/?%-]+)?(#[A-Za-z0-9._~!$&()*+,;=:@/?%-]+)?$'
    and link !~ '%(?![a-fA-F0-9]{2})';
end;

create type private.character_sheet_mode as enum ('inline', 'external');
alter table private.characters add column sheet_mode private.character_sheet_mode not null default 'inline',
  add column external_url text,
  add constraint characters_external_url_check check (
    external_url is null or (sheet_mode = 'external' and character_lifecycle.valid_external_url(external_url))
  );
alter table private.character_reviews add column examined_external_url text,
  add column examined_revision uuid,
  add column external_attested boolean not null default false,
  add column archived_character boolean not null default false
    check (not archived_character or decision = 'rejected'),
  add constraint review_external_evidence_check check (
    (examined_external_url is null and not external_attested)
    or (examined_external_url is not null and external_attested and examined_revision is not null
      and character_lifecycle.valid_external_url(examined_external_url))
  );
update private.character_reviews r set archived_character = true
from private.characters c where c.current_review_id = r.id and c.archived_at is not null;

create unique index character_review_examined_revision_idx on private.character_reviews (character_id, examined_revision)
  where examined_revision is not null;

revoke all on function character_lifecycle.valid_external_url(text) from public, anon, authenticated, service_role;
grant execute on function character_lifecycle.valid_external_url(text) to hu_character_lifecycle, hu_character_review;
grant select (sheet_mode, external_url, refusal_count, archived_at),
  insert (sheet_mode, external_url), update (sheet_mode, external_url)
  on private.characters to hu_character_lifecycle;
grant select (sheet_mode, external_url, refusal_count, archived_at), update (refusal_count, archived_at)
  on private.characters to hu_character_review;
grant select (examined_external_url, examined_revision, external_attested, archived_character),
  insert (examined_external_url, examined_revision, external_attested, archived_character)
  on private.character_reviews to hu_character_review;
grant execute on function private.lock_character_capacity(uuid) to hu_character_review;
grant select (archived_at) on private.characters to authenticated;

-- As with Houses, permit only the row lock. An UPDATE cannot pass WITH CHECK.
grant update (is_active) on public.programs to hu_character_lifecycle;
create policy lifecycle_program_lock_active on public.programs for update to hu_character_lifecycle
  using (is_active) with check (false);

alter policy lifecycle_character_edit_own on private.characters
  using (archived_at is null and exists (select 1 from private.players p where p.id = player_id)
    and character_lifecycle.owner_can_change(validation_status))
  with check (archived_at is null and exists (select 1 from private.players p where p.id = player_id)
    and (character_lifecycle.owner_can_change(validation_status) or validation_status = 'submitted'));
alter policy lifecycle_profile_write_own on public.character_profiles
  using (exists (select 1 from private.characters c where c.id = character_id and c.archived_at is null
    and character_lifecycle.owner_can_change(c.validation_status)))
  with check (exists (select 1 from private.characters c where c.id = character_id and c.archived_at is null
    and character_lifecycle.owner_can_change(c.validation_status)));
alter policy lifecycle_sheet_write_own on private.character_sheets
  using (exists (select 1 from private.characters c where c.id = character_id and c.archived_at is null
    and character_lifecycle.owner_can_change(c.validation_status)))
  with check (exists (select 1 from private.characters c where c.id = character_id and c.archived_at is null
    and character_lifecycle.owner_can_change(c.validation_status)));

create or replace function character_lifecycle.owner_can_change(state private.validation_status) returns boolean
language sql immutable security invoker set search_path = ''
begin atomic
  select state in ('draft', 'changes_requested', 'rejected');
end;

create or replace function character_lifecycle.capacity(owner_id uuid) returns jsonb
language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object('total', cap.allowed_slots, 'used', usage.used,
    'available', greatest(0, cap.allowed_slots - usage.used))
  from private.player_slot_capacity cap
  cross join lateral (select count(*) as used from private.characters c where c.player_id = cap.player_id and c.archived_at is null) usage
  where cap.player_id = owner_id;
$$;

create or replace function character_lifecycle.valid_fields(fields jsonb) returns boolean
language plpgsql immutable security invoker set search_path = '' as $$
declare
  field record;
  maximum integer;
  entry jsonb;
begin
  if jsonb_typeof(fields) is distinct from 'object' or octet_length(fields::text) > 98304 then
    return false;
  end if;
  for field in select key, value from jsonb_each(fields) loop
    maximum := case field.key
      when 'firstName' then 80 when 'lastName' then 80 when 'nickname' then 80
      when 'birthPlace' then 200 when 'sexualOrientation' then 120 when 'origins' then 200
      when 'residence' then 200 when 'financialSituation' then 200 when 'occupation' then 200
      when 'faceClaim' then 300 when 'personality' then 4000 when 'physicalDescription' then 4000
      when 'backstory' then 12000 when 'anecdotes' then 4000
      else null end;
    if maximum is not null then
      if field.value <> 'null'::jsonb and
        (jsonb_typeof(field.value) <> 'string' or length(field.value #>> '{}') > maximum
         or field.value #>> '{}' !~ '[^[:space:]]') then return false; end if;
    elsif field.key = 'sheetMode' then
      if jsonb_typeof(field.value) <> 'string' or field.value #>> '{}' not in ('inline', 'external')
        then return false; end if;
    elsif field.key = 'externalUrl' then
      if field.value <> 'null'::jsonb and (jsonb_typeof(field.value) <> 'string'
        or not character_lifecycle.valid_external_url(field.value #>> '{}')) then return false; end if;
    elsif field.key = 'age' then
      if field.value <> 'null'::jsonb and (jsonb_typeof(field.value) <> 'number'
        or field.value::numeric not between 0 and 32767 or mod(field.value::numeric, 1) <> 0)
        then return false; end if;
    elsif field.key = 'birthDate' then
      if field.value <> 'null'::jsonb then
        if jsonb_typeof(field.value) <> 'string' or field.value #>> '{}' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
          then return false; end if;
        perform (field.value #>> '{}')::date;
      end if;
    elsif field.key = 'programId' then
      if field.value <> 'null'::jsonb and (jsonb_typeof(field.value) <> 'string'
        or field.value #>> '{}' !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
        then return false; end if;
    elsif field.key = 'isScholarshipHolder' then
      if jsonb_typeof(field.value) not in ('null', 'boolean') then return false; end if;
    elsif field.key in ('contentWarnings', 'rpLinks') then
      if field.value = 'null'::jsonb then continue; end if;
      if jsonb_typeof(field.value) <> 'array' then return false; end if;
      if jsonb_array_length(field.value) > 12 then return false; end if;
      maximum := case field.key when 'contentWarnings' then 120 else 300 end;
      for entry in select value from jsonb_array_elements(field.value) loop
        if jsonb_typeof(entry) <> 'string' or length(entry #>> '{}') > maximum
          or entry #>> '{}' !~ '[^[:space:]]' then return false; end if;
      end loop;
    else
      return false;
    end if;
  end loop;
  return true;
exception
  when invalid_datetime_format or datetime_field_overflow or invalid_parameter_value then return false;
end;
$$;

create function character_lifecycle.normalized_lines(content text) returns text
language sql immutable strict security invoker set search_path = ''
begin atomic
  select replace(replace(content, E'\r\n', E'\n'), E'\r', E'\n');
end;
create function character_lifecycle.editorial_lines(content text) returns integer
language sql immutable security invoker set search_path = ''
begin atomic
  select count(*)::integer
  from unnest(string_to_array(character_lifecycle.normalized_lines(content), E'\n')) as line(value)
  where btrim(line.value, U&'\0009\000B\000C\0020\0085\00A0\1680\2000\2001\2002\2003\2004\2005\2006\2007\2008\2009\200A\2028\2029\202F\205F\3000\FEFF') <> '';
end;
revoke all on function character_lifecycle.normalized_lines(text), character_lifecycle.editorial_lines(text)
  from public, anon, authenticated, service_role;
grant execute on function character_lifecycle.normalized_lines(text), character_lifecycle.editorial_lines(text)
  to hu_character_lifecycle;

create or replace function character_lifecycle.save_sheet(target_id uuid, fields jsonb) returns void
language plpgsql volatile security invoker set search_path = '' as $$
begin
  insert into public.character_profiles (character_id, first_name, last_name, nickname)
    values (target_id, fields ->> 'firstName', fields ->> 'lastName', fields ->> 'nickname')
    on conflict (character_id) do update set
      first_name = excluded.first_name, last_name = excluded.last_name, nickname = excluded.nickname;

  insert into private.character_sheets (
    character_id, age, sexual_orientation, birth_date, birth_place, origins, residence,
    financial_situation, occupation, personality, physical_description, face_claim,
    backstory, anecdotes, content_warnings, rp_links)
  values (
    target_id, (fields ->> 'age')::numeric::smallint, fields ->> 'sexualOrientation',
    (fields ->> 'birthDate')::date, fields ->> 'birthPlace', fields ->> 'origins',
    fields ->> 'residence', fields ->> 'financialSituation', fields ->> 'occupation',
    character_lifecycle.normalized_lines(fields ->> 'personality'),
    character_lifecycle.normalized_lines(fields ->> 'physicalDescription'), fields ->> 'faceClaim',
    character_lifecycle.normalized_lines(fields ->> 'backstory'), fields ->> 'anecdotes',
    case when jsonb_typeof(fields -> 'contentWarnings') = 'array'
      then array(select jsonb_array_elements_text(fields -> 'contentWarnings')) end,
    case when jsonb_typeof(fields -> 'rpLinks') = 'array'
      then array(select jsonb_array_elements_text(fields -> 'rpLinks')) end)
  on conflict (character_id) do update set
    age = excluded.age, sexual_orientation = excluded.sexual_orientation,
    birth_date = excluded.birth_date, birth_place = excluded.birth_place, origins = excluded.origins,
    residence = excluded.residence, financial_situation = excluded.financial_situation,
    occupation = excluded.occupation, personality = excluded.personality,
    physical_description = excluded.physical_description, face_claim = excluded.face_claim,
    backstory = excluded.backstory, anecdotes = excluded.anecdotes,
    content_warnings = excluded.content_warnings, rp_links = excluded.rp_links;
end;
$$;

create or replace function character_review.history(target_id uuid) returns jsonb
language sql stable security invoker set search_path = ''
begin atomic
  select coalesce(jsonb_agg(jsonb_build_object(
    'decision', r.decision, 'reviewedAt', r.reviewed_at,
    'comment', r.note, 'assignedHouseId', r.assigned_house_id,
    'examinedRevision', r.examined_revision, 'archivedCharacter', r.archived_character,
    'externalEvidence', case when r.external_attested then jsonb_build_object(
      'url', r.examined_external_url, 'attested', true) end
  ) order by r.reviewed_at, r.id), '[]'::jsonb)
  from private.character_reviews r
  where r.character_id = target_id;
end;

grant create on schema character_review to hu_character_review;
set local role hu_character_review;

create or replace function character_review.staff_request(
  operation text, target_id uuid, page_size integer, after_id uuid, decision_input jsonb
) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  caller uuid := character_lifecycle.session_user_id();
  actor_id uuid;
  target record;
  entries jsonb;
  next_cursor uuid;
  expected_revision uuid;
  outcome private.validation_status;
  player_comment text;
  assigned_house uuid;
  review_id uuid;
  decision_time timestamptz;
  next_revision uuid;
  active_house uuid;
  owner_id uuid;
  updated_refusal_count integer;
  archived timestamptz;
  attested boolean;
  house_is_active boolean;
begin
  if caller is null then return jsonb_build_object('status', 'unauthenticated'); end if;
  actor_id := character_review.own_player();
  if actor_id is null then return jsonb_build_object('status', 'player_link_required'); end if;
  if not character_review.can_review() then return jsonb_build_object('status', 'forbidden'); end if;

  if operation is null or operation not in ('queue', 'detail', 'history', 'decide')
    or (target_id is null) <> (operation = 'queue')
    or (operation <> 'queue' and (page_size is not null or after_id is not null))
    or (decision_input is not null) <> (operation = 'decide') then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  if operation = 'queue' then
    page_size := coalesce(page_size, 20);
    if page_size not between 1 and 50 then return jsonb_build_object('status', 'invalid_request'); end if;
    with page as (
      select c.id, c.kind, c.revision, c.use_status, c.updated_at, p.first_name, p.last_name
      from private.characters c left join public.character_profiles p on p.character_id = c.id
      where c.validation_status = 'submitted' and c.player_id <> actor_id
        and (after_id is null or c.id > after_id)
      order by c.id
      limit page_size + 1
    ), numbered as (
      select page.*, row_number() over (order by id) as position from page
    )
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', id, 'kind', kind, 'revision', revision, 'useStatus', use_status,
      'updatedAt', updated_at, 'firstName', first_name, 'lastName', last_name
    ) order by id) filter (where position <= page_size), '[]'::jsonb),
      case when count(*) > page_size then ((array_agg(id order by id))[page_size]) end
    into entries, next_cursor from numbered;
    return jsonb_build_object('status', 'ok', 'data', jsonb_build_object('items', entries, 'nextCursor', next_cursor));
  end if;

  if operation = 'detail' then
    -- Project the sheet only while it is submitted. The projection and state
    -- check use the same snapshot even when a player or reviewer races this read.
    select character_lifecycle.details(c.player_id, c.id) into entries
      from private.characters c
      where c.id = target_id and c.player_id <> actor_id and c.validation_status = 'submitted';
    if not found then return jsonb_build_object('status', 'not_found'); end if;
    return jsonb_build_object('status', 'ok', 'data', entries);
  end if;

  if operation = 'history' then
    select character_review.history(c.id) into entries from private.characters c
      where c.id = target_id and c.player_id <> actor_id and c.validation_status <> 'draft'
        and (c.archived_at is null or character_review.can_reopen());
    if not found then return jsonb_build_object('status', 'not_found'); end if;
    return jsonb_build_object('status', 'ok', 'data', entries);
  end if;

  if jsonb_typeof(decision_input) is distinct from 'object'
    or octet_length(decision_input::text) > 32768 then
    return jsonb_build_object('status', 'invalid_request');
  end if;
  if decision_input - array['decision', 'expectedRevision', 'comment', 'houseId', 'externalAttested'] <> '{}'::jsonb
    or jsonb_typeof(decision_input -> 'decision') is distinct from 'string'
    or decision_input ->> 'decision' not in ('approved', 'changes_requested', 'rejected')
    or jsonb_typeof(decision_input -> 'expectedRevision') is distinct from 'string'
    or decision_input ->> 'expectedRevision' !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    or (decision_input ? 'houseId' and (
      jsonb_typeof(decision_input -> 'houseId') <> 'string'
      or decision_input ->> 'houseId' !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    ))
    or (decision_input ? 'externalAttested'
      and jsonb_typeof(decision_input -> 'externalAttested') <> 'boolean')
    or (decision_input ? 'comment' and (
      jsonb_typeof(decision_input -> 'comment') <> 'string'
      or length(decision_input ->> 'comment') > 2000
      or decision_input ->> 'comment' !~ '[^[:space:]]'
    )) then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  -- Authorization rechecks must observe changes committed during the lock wait.
  if current_setting('transaction_isolation') <> 'read committed' then
    return jsonb_build_object('status', 'unavailable');
  end if;
  -- Global write lock order: player capacity, character, then House.
  select c.player_id into owner_id from private.characters c
    where c.id = target_id and c.player_id <> actor_id and c.validation_status = 'submitted';
  if owner_id is not null and decision_input ->> 'decision' = 'rejected' then
    perform private.lock_character_capacity(owner_id);
  end if;
  select c.player_id, c.refusal_count, c.sheet_mode, c.external_url, c.kind, c.validation_status, c.revision, c.house_id, c.house_review_id into target
    from private.characters c
    where c.id = target_id and c.player_id <> actor_id and c.validation_status = 'submitted'
    for update;

  if character_lifecycle.session_user_id() is distinct from caller then
    return jsonb_build_object('status', 'unauthenticated');
  end if;
  if character_review.own_player() is distinct from actor_id or not character_review.can_review() then
    return jsonb_build_object('status', 'forbidden');
  end if;
  if target.player_id is null then
    if exists (select 1 from private.characters c where c.id = target_id
      and c.player_id <> actor_id and c.validation_status <> 'draft') then
      return jsonb_build_object('status', 'not_submitted');
    end if;
    return jsonb_build_object('status', 'not_found');
  end if;
  if target.player_id = actor_id then return jsonb_build_object('status', 'not_found'); end if;
  if target.validation_status <> 'submitted' then return jsonb_build_object('status', 'not_submitted'); end if;

  expected_revision := (decision_input ->> 'expectedRevision')::uuid;
  if target.revision <> expected_revision then return jsonb_build_object('status', 'revision_conflict'); end if;
  outcome := (decision_input ->> 'decision')::private.validation_status;
  player_comment := decision_input ->> 'comment';
  assigned_house := (decision_input ->> 'houseId')::uuid;
  if outcome <> 'approved' and player_comment is null then
    return jsonb_build_object('status', 'comment_required');
  end if;
  if assigned_house is not null then
    if target.kind <> 'student' or outcome <> 'approved' then
      return jsonb_build_object('status', 'invalid_house');
    end if;

    -- Serialize with deactivation. A catalog change that commits before this
    -- lock is granted must be reflected in the eligibility check.
    perform h.id from public.houses h
    where h.id = assigned_house and h.is_active for share;
    house_is_active := found;

    if character_lifecycle.session_user_id() is distinct from caller then
      return jsonb_build_object('status', 'unauthenticated');
    end if;
    if character_review.own_player() is distinct from actor_id or not character_review.can_review() then
      return jsonb_build_object('status', 'forbidden');
    end if;

    if not house_is_active then
      return jsonb_build_object('status', 'invalid_house');
    end if;
  end if;
  active_house := coalesce(assigned_house, target.house_id);
  if outcome = 'approved' and target.kind = 'student' and active_house is null then
    return jsonb_build_object('status', 'house_required');
  end if;

  attested := coalesce((decision_input ->> 'externalAttested')::boolean, false);
  if attested <> (target.sheet_mode = 'external')
    or (attested and target.external_url is null) then
    return jsonb_build_object('status', 'invalid_attestation');
  end if;
  decision_time := clock_timestamp();
  updated_refusal_count := target.refusal_count + case when outcome = 'rejected' then 1 else 0 end;
  archived := case when outcome = 'rejected' and updated_refusal_count >= 3 then decision_time end;
  insert into private.character_reviews as r (character_id, player_id, reviewer_id, decision, note, assigned_house_id, reviewed_at,
    examined_revision, examined_external_url, external_attested, archived_character)
  values (target_id, target.player_id, actor_id, outcome, player_comment, assigned_house, decision_time,
    expected_revision, case when attested then target.external_url end, attested, archived is not null)
  returning r.id into review_id;
  update private.characters c set validation_status = outcome, current_review_id = review_id,
    refusal_count = updated_refusal_count, archived_at = archived,
    house_id = active_house, house_review_id = case when assigned_house is not null then review_id else target.house_review_id end
    where c.id = target_id
    returning c.revision into next_revision;
  if not found then raise sqlstate 'P0901'; end if;

  return jsonb_build_object('status', 'ok', 'data', jsonb_build_object(
    'characterId', target_id, 'revision', next_revision, 'houseId', active_house,
    'refusalCount', updated_refusal_count, 'archivedAt', archived,
    'review', jsonb_build_object('decision', outcome, 'reviewedAt', decision_time,
      'comment', player_comment, 'assignedHouseId', assigned_house, 'examinedRevision', expected_revision,
      'archivedCharacter', archived is not null,
      'externalEvidence', case when attested then jsonb_build_object('url', target.external_url, 'attested', true) end)));
exception
  when sqlstate 'P0901' or insufficient_privilege then
    return jsonb_build_object('status', 'forbidden');
  when integrity_constraint_violation then
    return jsonb_build_object('status', 'unavailable');
end;
$$;
reset role;
revoke create on schema character_review from hu_character_review;
create or replace function public.current_player_context() returns jsonb
language sql
stable
security invoker
set search_path = ''
begin atomic
  select jsonb_build_object(
    'playerId', p.id,
    'capabilities', coalesce((
      select jsonb_agg(g.capability order by g.capability)
      from private.staff_capabilities g
      where g.staff_actor_id = p.id
    ), '[]'::jsonb),
    'characters', coalesce(c.characters, '[]'::jsonb),
    'canAccessCampus', coalesce(c.can_access_campus, false)
  )
  from private.players p
  cross join lateral (
    select
      jsonb_agg(jsonb_build_object(
        'id', owned.id,
        'validationStatus', owned.validation_status,
        'useStatus', owned.use_status,
        'canAccessCampus', owned.can_access_campus
      ) order by owned.id) as characters,
      bool_or(owned.can_access_campus) as can_access_campus
    from (
      select
        ch.id, ch.validation_status, ch.use_status,
        ch.validation_status = 'approved' and ch.use_status = 'active' as can_access_campus
      from private.characters ch
      where ch.player_id = p.id and ch.archived_at is null
    ) owned
  ) c
  where p.auth_user_id = (select auth.uid());
end;


-- Pending requests reserve no slot. The review reference identifies the archive
-- cycle, and unique request IDs plus the cycle prevent stale writes and replays.
create table private.character_reopen_requests (
  id uuid primary key,
  character_id uuid not null,
  player_id uuid not null,
  archive_review_id uuid not null,
  archive_decision private.validation_status generated always as ('rejected'::private.validation_status) stored,
  requested_revision uuid not null,
  reason text not null check (length(reason) <= 2000 and reason ~ '[^[:space:]]'),
  requested_at timestamptz not null default clock_timestamp(),
  decision text check (decision in ('accepted', 'declined')),
  justification text check (length(justification) <= 2000 and justification ~ '[^[:space:]]'),
  decided_by uuid references private.staff_actors(player_id),
  decided_at timestamptz,
  resulting_revision uuid,
  foreign key (character_id, player_id) references private.characters(id, player_id),
  foreign key (character_id, archive_review_id, archive_decision)
    references private.character_reviews(character_id, id, decision),
  check (decided_by <> player_id),
  check (
    (decision is null and justification is null and decided_by is null
      and decided_at is null and resulting_revision is null)
    or (decision is not null and justification is not null and decided_by is not null
      and decided_at is not null and (resulting_revision is not null) = (decision = 'accepted'))
  )
);
create unique index character_reopen_one_pending_idx on private.character_reopen_requests (character_id, archive_review_id)
  where decision is null;
create index character_reopen_timeline_idx on private.character_reopen_requests (character_id, requested_at, id);

alter table private.character_reopen_requests enable row level security;
revoke all on private.character_reopen_requests from public, anon, authenticated, service_role;
grant select (id, character_id, player_id, archive_review_id, requested_revision, reason, requested_at,
    decision, justification, decided_at, resulting_revision),
  insert (id, character_id, player_id, archive_review_id, requested_revision, reason),
  update (decision, justification, decided_by, decided_at, resulting_revision)
  on private.character_reopen_requests to hu_character_review;
grant select (character_id, player_id, archive_review_id, decision)
  on private.character_reopen_requests to hu_character_lifecycle;
grant select (current_review_id) on private.characters to hu_character_lifecycle, hu_character_review;
grant select (player_id, revision, confirmed_active_boosts) on private.boost_confirmations to hu_character_review;
alter policy review_capability_self on private.staff_capabilities using (
  capability in ('characters.review', 'characters.reopen')
    and exists (select 1 from private.players p where p.id = staff_actor_id)
);

grant create on schema character_review to hu_character_review;
set local role hu_character_review;
create function character_review.can_reopen() returns boolean
language sql stable security invoker set search_path = ''
begin atomic
  select exists (select 1 from private.staff_capabilities where capability = 'characters.reopen');
end;
revoke all on function character_review.can_reopen() from public, anon, authenticated, service_role;
reset role;

create policy review_reopen_boosts on private.boost_confirmations for select to hu_character_review
  using ((select character_review.can_reopen()));
alter policy review_character_visible on private.characters using (
  player_id = (select character_review.own_player())
  or (validation_status <> 'draft' and (select character_review.can_review()))
  -- Count all occupied rows during acceptance, and allow RETURNING the draft
  -- revision. The RPCs restrict staff projections to archives and request history.
  or (select character_review.can_reopen())
);
create policy review_reopen_character on private.characters for update to hu_character_review
  using (archived_at is not null and player_id <> (select character_review.own_player())
    and (select character_review.can_reopen()))
  with check (archived_at is null and validation_status = 'draft' and current_review_id is null
    and player_id <> (select character_review.own_player()) and (select character_review.can_reopen()));
alter policy review_profile_submitted on public.character_profiles using (
  exists (select 1 from private.characters c where c.id = character_id
    and ((c.validation_status = 'submitted' and c.player_id <> (select character_review.own_player())
          and (select character_review.can_review()))
      or (c.archived_at is not null and (select character_review.can_reopen()))))
);
alter policy review_sheet_submitted on private.character_sheets using (
  exists (select 1 from private.characters c where c.id = character_id
    and ((c.validation_status = 'submitted' and c.player_id <> (select character_review.own_player())
          and (select character_review.can_review()))
      or (c.archived_at is not null and (select character_review.can_reopen()))))
);
create policy lifecycle_reopen_requests_read on private.character_reopen_requests for select to hu_character_lifecycle
  using (exists (select 1 from private.players p where p.id = player_id));
create policy review_reopen_requests_read on private.character_reopen_requests for select to hu_character_review
  using (player_id = (select character_review.own_player()) or (select character_review.can_reopen()));
create policy review_reopen_requests_create on private.character_reopen_requests for insert to hu_character_review
  with check (player_id = (select character_review.own_player()) and decision is null
    and exists (select 1 from private.characters c where c.id = character_id and c.player_id = character_reopen_requests.player_id
      and c.archived_at is not null and c.current_review_id = archive_review_id and c.revision = requested_revision));
create policy review_reopen_requests_decide on private.character_reopen_requests for update to hu_character_review
  using (decision is null and player_id <> (select character_review.own_player())
    and (select character_review.can_reopen()))
  with check (decided_by = (select character_review.own_player()) and player_id <> decided_by
    and (select character_review.can_reopen()) and decision is not null);

-- Shared by owner list and detail. Staff archive access exposes its own
-- action through the pending request ID, and does not imply owner actions.
create function character_lifecycle.owner_actions(
  owner_id uuid, target_id uuid, state private.validation_status, archive_review uuid
) returns jsonb language sql stable security invoker set search_path = ''
begin atomic
  select jsonb_build_object(
    'canEdit', archive_review is null and character_lifecycle.owner_can_change(state),
    'canSubmit', archive_review is null and character_lifecycle.owner_can_change(state),
    'canRequestReopening', archive_review is not null
      and exists (select 1 from private.players p where p.id = owner_id and p.auth_user_id = auth.uid())
      and not exists (select 1 from private.character_reopen_requests r
        where r.character_id = target_id and r.archive_review_id = archive_review and r.decision is null)
  );
end;
revoke all on function character_lifecycle.owner_actions(uuid, uuid, private.validation_status, uuid)
  from public, anon, authenticated, service_role;
grant execute on function character_lifecycle.owner_actions(uuid, uuid, private.validation_status, uuid)
  to hu_character_lifecycle, hu_character_review;
grant execute on function character_lifecycle.owner_can_change(private.validation_status) to hu_character_review;

set local role hu_character_review;
create function character_review.reopening_request(
  operation text, target_id uuid, args jsonb, page_size integer, after_id uuid
) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  caller uuid := character_lifecycle.session_user_id();
  actor uuid;
  staff_action boolean;
  owner_id uuid;
  target record;
  request_row record;
  request_id uuid;
  expected_revision uuid;
  message text;
  outcome text;
  replacement_revision uuid;
  decision_time timestamptz;
  capacity bigint;
  data jsonb;
begin
  if caller is null then return jsonb_build_object('status', 'unauthenticated'); end if;
  actor := character_review.own_player();
  if actor is null then return jsonb_build_object('status', 'player_link_required'); end if;
  if operation is null or operation not in ('owner_history', 'request', 'staff_archives', 'staff_detail', 'staff_history', 'resolve')
    or (target_id is null) <> (operation = 'staff_archives')
    or (args is not null) <> (operation in ('request', 'resolve'))
    or (operation <> 'staff_archives' and (page_size is not null or after_id is not null)) then
    return jsonb_build_object('status', 'invalid_request');
  end if;
  staff_action := operation in ('staff_archives', 'staff_detail', 'staff_history', 'resolve');
  if staff_action and not character_review.can_reopen() then
    return jsonb_build_object('status', 'reopening_forbidden');
  end if;

  if operation = 'staff_archives' then
    page_size := coalesce(page_size, 20);
    if page_size not between 1 and 50 then return jsonb_build_object('status', 'invalid_request'); end if;
    with page as (
      select c.id, c.kind, c.revision, c.archived_at, c.refusal_count, p.first_name, p.last_name,
        (select r.id from private.character_reopen_requests r
         where r.character_id = c.id and r.archive_review_id = c.current_review_id and r.decision is null) as pending_id
      from private.characters c left join public.character_profiles p on p.character_id = c.id
      where c.archived_at is not null and (after_id is null or c.id > after_id)
      order by c.id limit page_size + 1
    ), numbered as (
      select page.*, row_number() over (order by id) as position from page
    )
    select jsonb_build_object('items', coalesce(jsonb_agg(jsonb_build_object(
      'id', id, 'kind', kind, 'revision', revision, 'archivedAt', archived_at, 'refusalCount', refusal_count,
      'firstName', first_name, 'lastName', last_name, 'pendingRequestId', pending_id
    ) order by id) filter (where position <= page_size), '[]'::jsonb),
    'nextCursor', case when count(*) > page_size then ((array_agg(id order by id))[page_size]) end)
    into data from numbered;
    return jsonb_build_object('status', 'ok', 'data', data);
  end if;

  if operation = 'staff_detail' then
    select jsonb_build_object('sheet', character_lifecycle.details(c.player_id, c.id),
      'reviews', character_review.history(c.id)) into data
    from private.characters c where c.id = target_id and c.archived_at is not null;
    if not found then return jsonb_build_object('status', 'not_found'); end if;
    return jsonb_build_object('status', 'ok', 'data', data);
  end if;

  if operation in ('owner_history', 'staff_history') then
    select coalesce(jsonb_agg(jsonb_build_object(
      'requestId', r.id, 'requestedRevision', r.requested_revision, 'reason', r.reason,
      'requestedAt', r.requested_at, 'decision', r.decision, 'justification', r.justification,
      'decidedAt', r.decided_at, 'resultingRevision', r.resulting_revision
    ) order by r.requested_at, r.id) filter (where r.id is not null), '[]'::jsonb)
    into data from private.characters c left join private.character_reopen_requests r on r.character_id = c.id
    where c.id = target_id and ((not staff_action and c.player_id = actor)
      or (staff_action and (c.archived_at is not null or r.id is not null)))
    group by c.id;
    if not found then return jsonb_build_object('status', 'not_found'); end if;
    return jsonb_build_object('status', 'ok', 'data', data);
  end if;

  if jsonb_typeof(args) is distinct from 'object' or octet_length(args::text) > 32768
    or args - (case when staff_action then array['requestId', 'expectedRevision', 'decision', 'justification']
      else array['requestId', 'expectedRevision', 'reason'] end) <> '{}'::jsonb
    or jsonb_typeof(args -> 'requestId') is distinct from 'string'
    or jsonb_typeof(args -> 'expectedRevision') is distinct from 'string'
    or args ->> 'requestId' !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    or args ->> 'expectedRevision' !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    or (staff_action and (jsonb_typeof(args -> 'decision') is distinct from 'string'
      or args ->> 'decision' not in ('accepted', 'declined')))
    or jsonb_typeof(args -> (case when staff_action then 'justification' else 'reason' end)) is distinct from 'string'
  then return jsonb_build_object('status', 'invalid_request'); end if;
  message := args ->> (case when staff_action then 'justification' else 'reason' end);
  if length(message) > 2000 or message !~ '[^[:space:]]' then
    return jsonb_build_object('status', 'invalid_request');
  end if;
  request_id := (args ->> 'requestId')::uuid;
  expected_revision := (args ->> 'expectedRevision')::uuid;
  outcome := args ->> 'decision';

  if current_setting('transaction_isolation') <> 'read committed' then
    return jsonb_build_object('status', 'unavailable');
  end if;
  select c.player_id into owner_id from private.characters c
    where c.id = target_id and c.archived_at is not null and (c.player_id = actor) <> staff_action;
  if not found then return jsonb_build_object('status', 'not_found'); end if;

  -- Serialize even requests/declines with the cycle and capacity changes.
  perform private.lock_character_capacity(owner_id);

  -- The owner must not receive UPDATE privileges on archived characters merely
  -- to acquire a row lock. The capacity lock already serializes archive writes.
  if staff_action then
    select c.revision, c.current_review_id into target from private.characters c
      where c.id = target_id and c.player_id = owner_id and c.archived_at is not null for update;
  else
    select c.revision, c.current_review_id into target from private.characters c
      where c.id = target_id and c.player_id = actor and c.archived_at is not null;
  end if;

  if character_lifecycle.session_user_id() is distinct from caller then
    return jsonb_build_object('status', 'unauthenticated');
  end if;
  if character_review.own_player() is distinct from actor
    or (staff_action and not character_review.can_reopen()) then
    return jsonb_build_object('status', 'reopening_forbidden');
  end if;
  if target.revision is null then return jsonb_build_object('status', 'not_found'); end if;
  if target.revision <> expected_revision then return jsonb_build_object('status', 'revision_conflict'); end if;

  if not staff_action then
    insert into private.character_reopen_requests (
      id, character_id, player_id, archive_review_id, requested_revision, reason
    ) values (request_id, target_id, actor, target.current_review_id, expected_revision, message)
    on conflict do nothing returning requested_at into decision_time;
    if not found then return jsonb_build_object('status', 'reopening_conflict'); end if;
    return jsonb_build_object('status', 'ok', 'data', jsonb_build_object(
      'requestId', request_id, 'requestedRevision', expected_revision, 'reason', message,
      'requestedAt', decision_time, 'decision', null, 'justification', null, 'decidedAt', null, 'resultingRevision', null));
  end if;

  select r.requested_revision, r.reason, r.requested_at into request_row
    from private.character_reopen_requests r where r.id = request_id and r.character_id = target_id
      and r.player_id = owner_id and r.archive_review_id = target.current_review_id and r.decision is null;
  if not found then return jsonb_build_object('status', 'reopening_conflict'); end if;

  if outcome = 'accepted' then
    select 5 + coalesce((select b.confirmed_active_boosts from private.boost_confirmations b
      where b.player_id = owner_id order by b.revision desc limit 1), 0)::bigint into capacity;
    if (select count(*) from private.characters c where c.player_id = owner_id and c.archived_at is null) >= capacity then
      return jsonb_build_object('status', 'capacity_reached');
    end if;
    update private.characters c set archived_at = null, validation_status = 'draft', current_review_id = null
      where c.id = target_id returning c.revision into replacement_revision;
    if not found then raise sqlstate 'P0901'; end if;
  end if;

  decision_time := clock_timestamp();
  update private.character_reopen_requests r set decision = outcome, justification = message,
    decided_by = actor, decided_at = decision_time, resulting_revision = replacement_revision
    where r.id = request_id and r.decision is null;
  if not found then raise sqlstate 'P0901'; end if;
  return jsonb_build_object('status', 'ok', 'data', jsonb_build_object(
    'requestId', request_id, 'requestedRevision', request_row.requested_revision, 'reason', request_row.reason,
    'requestedAt', request_row.requested_at, 'decision', outcome, 'justification', message,
    'decidedAt', decision_time, 'resultingRevision', replacement_revision));
exception
  when sqlstate 'P0901' or insufficient_privilege then return jsonb_build_object('status', 'reopening_forbidden');
  when integrity_constraint_violation then return jsonb_build_object('status', 'unavailable');
end;
$$;
revoke all on function character_review.reopening_request(text, uuid, jsonb, integer, uuid)
  from public, anon, authenticated, service_role;
grant execute on function character_review.reopening_request(text, uuid, jsonb, integer, uuid) to authenticated;
reset role;
revoke create on schema character_review from hu_character_review;

create function public.character_reopening(
  operation text, target_id uuid default null, args jsonb default null, page_size integer default null, after_id uuid default null
) returns jsonb
language sql volatile security invoker set search_path = ''
begin atomic
  select character_review.reopening_request(operation, target_id, args, page_size, after_id);
end;
revoke all on function public.character_reopening(text, uuid, jsonb, integer, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.character_reopening(text, uuid, jsonb, integer, uuid) to authenticated;

create or replace function character_lifecycle.details(owner_id uuid, target_id uuid) returns jsonb
language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object(
    'sheetMode', c.sheet_mode, 'refusalCount', c.refusal_count, 'archivedAt', c.archived_at,
    'actions', character_lifecycle.owner_actions(c.player_id, c.id, c.validation_status,
      case when c.archived_at is not null then c.current_review_id end),
    'externalUrl', c.external_url, 'id', c.id, 'kind', c.kind, 'validationStatus', c.validation_status, 'useStatus', c.use_status,
    'revision', c.revision, 'houseId', c.house_id, 'programId', c.program_id,
    'isScholarshipHolder', c.is_scholarship_holder, 'createdAt', c.created_at, 'updatedAt', c.updated_at,
    'firstName', p.first_name, 'lastName', p.last_name, 'nickname', p.nickname,
    'age', s.age, 'sexualOrientation', s.sexual_orientation, 'birthDate', s.birth_date,
    'birthPlace', s.birth_place, 'origins', s.origins, 'residence', s.residence,
    'financialSituation', s.financial_situation, 'occupation', s.occupation,
    'personality', s.personality, 'physicalDescription', s.physical_description,
    'faceClaim', s.face_claim, 'backstory', s.backstory, 'anecdotes', s.anecdotes,
    'contentWarnings', s.content_warnings, 'rpLinks', s.rp_links)
  from private.characters c
  left join public.character_profiles p on p.character_id = c.id
  left join private.character_sheets s on s.character_id = c.id
  where c.player_id = owner_id and c.id = target_id;
$$;
grant create on schema character_lifecycle to hu_character_lifecycle;
set local role hu_character_lifecycle;
create or replace function character_lifecycle.character_request(
  operation text, target_id uuid, expected_revision uuid, fields jsonb
) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  caller uuid := character_lifecycle.session_user_id();
  owner_id uuid;
  character_id uuid := target_id;
  current_status private.validation_status;
  archived timestamptz;
  chosen_mode private.character_sheet_mode;
  chosen_url text;
  character_kind private.character_kind;
  revision_id uuid;
  program uuid;
  sheet jsonb;
  capacity jsonb;
  violated_constraint text;
begin
  if caller is null then return jsonb_build_object('status', 'unauthenticated'); end if;
  select p.id into owner_id from private.players p where p.auth_user_id = caller;
  if owner_id is null then return jsonb_build_object('status', 'player_link_required'); end if;

  if operation is null or operation not in ('list', 'archives', 'detail', 'capacity', 'create', 'edit', 'submit')
    or (target_id is not null) <> (operation in ('detail', 'edit', 'submit'))
    or (expected_revision is not null) <> (operation in ('edit', 'submit'))
    or (fields is not null) <> (operation in ('create', 'edit')) then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  if operation in ('list', 'archives') then
    return jsonb_build_object('status', 'ok', 'data', coalesce((
      select jsonb_agg(jsonb_build_object(
        'sheetMode', c.sheet_mode, 'refusalCount', c.refusal_count, 'archivedAt', c.archived_at,
    'actions', character_lifecycle.owner_actions(c.player_id, c.id, c.validation_status,
      case when c.archived_at is not null then c.current_review_id end),
        'id', c.id, 'kind', c.kind, 'validationStatus', c.validation_status, 'useStatus', c.use_status,
        'revision', c.revision, 'createdAt', c.created_at, 'updatedAt', c.updated_at,
        'firstName', p.first_name, 'lastName', p.last_name, 'nickname', p.nickname
      ) order by c.created_at, c.id)
      from private.characters c left join public.character_profiles p on p.character_id = c.id
      where c.player_id = owner_id and (c.archived_at is not null) = (operation = 'archives')
    ), '[]'::jsonb));
  end if;
  if operation = 'capacity' then
    return jsonb_build_object('status', 'ok', 'data', character_lifecycle.capacity(owner_id));
  end if;
  if operation = 'detail' then
    sheet := character_lifecycle.details(owner_id, target_id);
    if sheet is null then return jsonb_build_object('status', 'not_found'); end if;
    return jsonb_build_object('status', 'ok', 'data', sheet);
  end if;

  if operation = 'create' then
    if jsonb_typeof(fields) <> 'object' or jsonb_typeof(fields -> 'kind') is distinct from 'string'
      or fields ->> 'kind' not in ('student', 'teacher', 'staff_member', 'citizen') then
      return jsonb_build_object('status', 'invalid_request');
    end if;
    character_kind := (fields ->> 'kind')::private.character_kind;
    fields := fields - 'kind';
  end if;

  if operation in ('create', 'edit') and (not character_lifecycle.valid_fields(fields)
    or (operation = 'edit' and fields = '{}'::jsonb)) then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  -- The capacity and session checks must see changes committed while waiting.
  if current_setting('transaction_isolation') <> 'read committed' then
    return jsonb_build_object('status', 'unavailable');
  end if;
  if operation = 'create' then
    perform private.lock_character_capacity(owner_id);
  else
    select c.validation_status, c.archived_at into current_status, archived from private.characters c
      where c.id = target_id and c.player_id = owner_id;
    if not found then return jsonb_build_object('status', 'not_found'); end if;
    if archived is not null or not character_lifecycle.owner_can_change(current_status) then
      return jsonb_build_object('status', 'character_locked');
    end if;
    select c.kind, c.revision into character_kind, revision_id from private.characters c
      where c.id = target_id and c.player_id = owner_id for update;
    if not found then return jsonb_build_object('status', 'character_locked'); end if;
  end if;

  -- Fail closed if revocation or unlinking committed while the request waited.
  if character_lifecycle.session_user_id() is distinct from caller then
    return jsonb_build_object('status', 'unauthenticated');
  end if;
  if not exists (select 1 from private.players p where p.id = owner_id and p.auth_user_id = caller) then
    return jsonb_build_object('status', 'player_link_required');
  end if;
  if operation <> 'create' and revision_id <> expected_revision then
    return jsonb_build_object('status', 'revision_conflict');
  end if;

  if operation <> 'create' then sheet := character_lifecycle.details(owner_id, target_id); end if;
  sheet := coalesce(sheet, '{}'::jsonb) || coalesce(fields, '{}'::jsonb);
  chosen_mode := coalesce((sheet ->> 'sheetMode')::private.character_sheet_mode, 'inline');
  chosen_url := sheet ->> 'externalUrl';
  if chosen_mode = 'inline' then
    if fields ->> 'externalUrl' is not null then return jsonb_build_object('status', 'invalid_request'); end if;
    chosen_url := null;
  end if;
  program := (sheet ->> 'programId')::uuid;
  if (operation = 'submit' or fields ? 'programId') and program is not null then
    if character_kind not in ('student', 'teacher') then
      return jsonb_build_object('status', 'invalid_program');
    end if;
    perform p.id from public.programs p where p.id = program and p.is_active for share;
    if not found then return jsonb_build_object('status', 'invalid_program'); end if;
    if character_lifecycle.session_user_id() is distinct from caller then
      return jsonb_build_object('status', 'unauthenticated');
    end if;
    if not exists (select 1 from private.players p where p.id = owner_id and p.auth_user_id = caller) then
      return jsonb_build_object('status', 'player_link_required');
    end if;
  end if;
  if (operation = 'submit' or fields ? 'isScholarshipHolder')
    and character_kind <> 'student' and sheet ->> 'isScholarshipHolder' is not null then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  if operation = 'submit' then
    if exists (
      select 1 from unnest(array['firstName', 'lastName', 'faceClaim']) as required(field)
      where coalesce(sheet ->> required.field, '') !~ '[^[:space:]]'
    ) or sheet ->> 'age' is null or sheet ->> 'birthDate' is null
      or (character_kind = 'student' and program is null)
      or (character_kind in ('teacher', 'staff_member') and coalesce(sheet ->> 'occupation', '') !~ '[^[:space:]]')
      or (chosen_mode = 'external' and chosen_url is null) then
      return jsonb_build_object('status', 'incomplete');
    end if;
    if chosen_mode = 'inline' and (
      character_lifecycle.editorial_lines(sheet ->> 'physicalDescription') < 5
      or character_lifecycle.editorial_lines(sheet ->> 'personality') not between 5 and 10
      or character_lifecycle.editorial_lines(sheet ->> 'backstory') not between 10 and 15
    ) then return jsonb_build_object('status', 'incomplete'); end if;
    update private.characters set validation_status = 'submitted', current_review_id = null
      where id = target_id and player_id = owner_id;
  else
    if operation = 'create' then
      capacity := character_lifecycle.capacity(owner_id);
      if (capacity ->> 'available')::bigint <= 0 then
        return jsonb_build_object('status', 'capacity_reached');
      end if;
      insert into private.characters (player_id, kind, program_id, is_scholarship_holder, sheet_mode, external_url)
        values (owner_id, character_kind, program, (sheet ->> 'isScholarshipHolder')::boolean, chosen_mode, chosen_url)
        returning id into character_id;
    else
      update private.characters set program_id = program,
        sheet_mode = chosen_mode, external_url = chosen_url,
        is_scholarship_holder = (sheet ->> 'isScholarshipHolder')::boolean
        where id = target_id and player_id = owner_id;
    end if;
    perform character_lifecycle.save_sheet(character_id, sheet);
  end if;

  return jsonb_build_object('status', 'ok', 'data', character_lifecycle.details(owner_id, character_id));
exception
  when foreign_key_violation then
    get stacked diagnostics violated_constraint = constraint_name;
    if violated_constraint = 'characters_program_id_fkey' then
      return jsonb_build_object('status', 'invalid_program');
    end if;
    return jsonb_build_object('status', 'unavailable');
  when integrity_constraint_violation then
    -- PostgreSQL constraint details can contain the failing row's sheet values.
    return jsonb_build_object('status', 'unavailable');
end;
$$;
reset role;
revoke create on schema character_lifecycle from hu_character_lifecycle;
