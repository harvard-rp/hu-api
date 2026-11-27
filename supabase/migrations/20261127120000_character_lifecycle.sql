-- HU-009A uses the existing character, sheet, profile and capacity records.
create role hu_character_lifecycle nologin noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls;
grant hu_character_lifecycle to postgres with inherit false, set true;

create schema character_lifecycle;
revoke all on schema character_lifecycle from public, anon, authenticated, service_role;
grant usage on schema character_lifecycle to authenticated;
grant usage, create on schema character_lifecycle to hu_character_lifecycle;
grant usage on schema private to hu_character_lifecycle;

alter table private.characters add column revision uuid not null default gen_random_uuid();

create function character_lifecycle.rotate_revision() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  new.revision := gen_random_uuid();
  return new;
end;
$$;
revoke all on function character_lifecycle.rotate_revision() from public, anon, authenticated, service_role;
create trigger characters_rotate_revision before update on private.characters
  for each row execute function character_lifecycle.rotate_revision();

-- Capacity writers lock before reading or changing a player's allowance.
create function private.lock_character_capacity(owner_id uuid) returns void
language sql volatile security invoker set search_path = '' as $$
  select pg_advisory_xact_lock(hashtextextended(owner_id::text, 93001));
$$;
revoke all on function private.lock_character_capacity(uuid) from public, anon, authenticated, service_role;
grant execute on function private.lock_character_capacity(uuid) to hu_character_lifecycle;

create function private.lock_boost_confirmation() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  perform private.lock_character_capacity(new.player_id);
  return new;
end;
$$;
revoke all on function private.lock_boost_confirmation() from public, anon, authenticated, service_role;
create trigger boost_confirmations_lock_capacity before insert on private.boost_confirmations
  for each row execute function private.lock_boost_confirmation();

grant select (id, is_anonymous, banned_until) on auth.users to hu_character_lifecycle;
grant select (id, user_id, not_after) on auth.sessions to hu_character_lifecycle;
create policy character_lifecycle_auth_user on auth.users for select to hu_character_lifecycle
  using (id = (select auth.uid()));
create policy character_lifecycle_auth_session on auth.sessions for select to hu_character_lifecycle
  using (user_id = (select auth.uid()));

-- Bind Auth objects when creating this helper. Its invoker needs scoped column
-- privileges and passes Auth RLS without needing USAGE on the Auth schema.
create function character_lifecycle.session_user_id() returns uuid
language sql stable security invoker set search_path = ''
begin atomic
  with claims as (select auth.jwt() as jwt, auth.uid() as caller)
  select u.id
  from claims c
  join auth.users u on u.id = c.caller
  join auth.sessions s on s.user_id = u.id
    and s.id = case when c.jwt ->> 'session_id' ~
      '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
      then (c.jwt ->> 'session_id')::uuid end
  where c.jwt ->> 'sub' = c.caller::text
    and c.jwt ->> 'role' = 'authenticated'
    and c.jwt -> 'is_anonymous' = 'false'::jsonb
    and (c.jwt -> 'aud' = '"authenticated"'::jsonb
      or (jsonb_typeof(c.jwt -> 'aud') = 'array' and c.jwt -> 'aud' ? 'authenticated'))
    and case when jsonb_typeof(c.jwt -> 'exp') = 'number'
      then (c.jwt ->> 'exp')::numeric > extract(epoch from clock_timestamp())
      else false end
    and u.is_anonymous is false
    and (u.banned_until is null or u.banned_until <= clock_timestamp())
    and (s.not_after is null or s.not_after > clock_timestamp());
end;
revoke all on function character_lifecycle.session_user_id() from public, anon, authenticated, service_role;
grant execute on function character_lifecycle.session_user_id() to hu_character_lifecycle;

-- Provisional owner transition policy, shared by the RPC and its RLS policies.
create function character_lifecycle.owner_can_change(state private.validation_status) returns boolean
language sql immutable security invoker set search_path = ''
begin atomic
  select state in ('draft', 'changes_requested');
end;
revoke all on function character_lifecycle.owner_can_change(private.validation_status) from public, anon, authenticated, service_role;
grant execute on function character_lifecycle.owner_can_change(private.validation_status) to hu_character_lifecycle;

grant select (id, auth_user_id) on private.players to hu_character_lifecycle;
create policy lifecycle_player_owns_link on private.players for select to hu_character_lifecycle
  using (auth_user_id = (select auth.uid()));
grant select (player_id, revision, confirmed_active_boosts) on private.boost_confirmations to hu_character_lifecycle;
grant select (player_id, allowed_slots) on private.player_slot_capacity to hu_character_lifecycle;
create policy lifecycle_boost_read_own on private.boost_confirmations for select to hu_character_lifecycle
  using (exists (select 1 from private.players p where p.id = player_id));

grant select (id, player_id, kind, validation_status, use_status, revision, house_id,
    program_id, is_scholarship_holder, created_at, updated_at),
  insert (player_id, kind, program_id, is_scholarship_holder),
  update (program_id, is_scholarship_holder, validation_status, current_review_id)
  on private.characters to hu_character_lifecycle;
create policy lifecycle_character_read_own on private.characters for select to hu_character_lifecycle
  using (exists (select 1 from private.players p where p.id = player_id));
create policy lifecycle_character_create_own on private.characters for insert to hu_character_lifecycle
  with check (exists (select 1 from private.players p where p.id = player_id)
    and validation_status = 'draft' and use_status = 'active' and house_id is null);
create policy lifecycle_character_edit_own on private.characters for update to hu_character_lifecycle
  using (exists (select 1 from private.players p where p.id = player_id)
    and character_lifecycle.owner_can_change(validation_status))
  with check (exists (select 1 from private.players p where p.id = player_id)
    and (character_lifecycle.owner_can_change(validation_status) or validation_status = 'submitted'));

grant select (character_id, first_name, last_name, nickname),
  insert (character_id, first_name, last_name, nickname),
  update (first_name, last_name, nickname)
  on public.character_profiles to hu_character_lifecycle;
grant select (character_id, age, sexual_orientation, birth_date, birth_place, origins,
    residence, financial_situation, occupation, personality, physical_description, face_claim,
    backstory, anecdotes, content_warnings, rp_links),
  insert (character_id, age, sexual_orientation, birth_date, birth_place, origins,
    residence, financial_situation, occupation, personality, physical_description, face_claim,
    backstory, anecdotes, content_warnings, rp_links),
  update (age, sexual_orientation, birth_date, birth_place, origins,
    residence, financial_situation, occupation, personality, physical_description, face_claim,
    backstory, anecdotes, content_warnings, rp_links)
  on private.character_sheets to hu_character_lifecycle;

create policy lifecycle_profile_read_own on public.character_profiles for select to hu_character_lifecycle
  using (exists (select 1 from private.characters c where c.id = character_id));
create policy lifecycle_profile_write_own on public.character_profiles for all to hu_character_lifecycle
  using (exists (select 1 from private.characters c where c.id = character_id and character_lifecycle.owner_can_change(c.validation_status)))
  with check (exists (select 1 from private.characters c where c.id = character_id and character_lifecycle.owner_can_change(c.validation_status)));
create policy lifecycle_sheet_read_own on private.character_sheets for select to hu_character_lifecycle
  using (exists (select 1 from private.characters c where c.id = character_id));
create policy lifecycle_sheet_write_own on private.character_sheets for all to hu_character_lifecycle
  using (exists (select 1 from private.characters c where c.id = character_id and character_lifecycle.owner_can_change(c.validation_status)))
  with check (exists (select 1 from private.characters c where c.id = character_id and character_lifecycle.owner_can_change(c.validation_status)));

grant select (id, slug, name, is_active) on public.houses, public.programs to hu_character_lifecycle;
grant select (id, slug, name, is_active, member_capacity) on public.clubs to hu_character_lifecycle;
create policy lifecycle_houses_active on public.houses for select to hu_character_lifecycle using (is_active);
create policy lifecycle_programs_active on public.programs for select to hu_character_lifecycle using (is_active);
create policy lifecycle_clubs_active on public.clubs for select to hu_character_lifecycle using (is_active);

create function character_lifecycle.capacity(owner_id uuid) returns jsonb
language sql stable security invoker set search_path = '' as $$
  -- Provisional development policy: every existing row occupies one slot.
  select jsonb_build_object('total', cap.allowed_slots, 'used', usage.used,
    'available', greatest(0, cap.allowed_slots - usage.used))
  from private.player_slot_capacity cap
  cross join lateral (select count(*) as used from private.characters c where c.player_id = cap.player_id) usage
  where cap.player_id = owner_id;
$$;
revoke all on function character_lifecycle.capacity(uuid) from public, anon, authenticated, service_role;
grant execute on function character_lifecycle.capacity(uuid) to hu_character_lifecycle;

create function character_lifecycle.details(owner_id uuid, target_id uuid) returns jsonb
language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object(
    'id', c.id, 'kind', c.kind, 'validationStatus', c.validation_status, 'useStatus', c.use_status,
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
revoke all on function character_lifecycle.details(uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function character_lifecycle.details(uuid, uuid) to hu_character_lifecycle;

create function character_lifecycle.valid_fields(fields jsonb) returns boolean
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
revoke all on function character_lifecycle.valid_fields(jsonb) from public, anon, authenticated, service_role;
grant execute on function character_lifecycle.valid_fields(jsonb) to hu_character_lifecycle;

create function character_lifecycle.save_sheet(target_id uuid, fields jsonb) returns void
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
    fields ->> 'personality', fields ->> 'physicalDescription', fields ->> 'faceClaim',
    fields ->> 'backstory', fields ->> 'anecdotes',
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
revoke all on function character_lifecycle.save_sheet(uuid, jsonb) from public, anon, authenticated, service_role;
grant execute on function character_lifecycle.save_sheet(uuid, jsonb) to hu_character_lifecycle;

create function character_lifecycle.character_request(
  operation text, target_id uuid, expected_revision uuid, fields jsonb
) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  caller uuid := character_lifecycle.session_user_id();
  owner_id uuid;
  character_id uuid := target_id;
  current_status private.validation_status;
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

  if operation is null or operation not in ('list', 'detail', 'capacity', 'create', 'edit', 'submit')
    or (target_id is not null) <> (operation in ('detail', 'edit', 'submit'))
    or (expected_revision is not null) <> (operation in ('edit', 'submit'))
    or (fields is not null) <> (operation in ('create', 'edit')) then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  if operation = 'list' then
    return jsonb_build_object('status', 'ok', 'data', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', c.id, 'kind', c.kind, 'validationStatus', c.validation_status, 'useStatus', c.use_status,
        'revision', c.revision, 'createdAt', c.created_at, 'updatedAt', c.updated_at,
        'firstName', p.first_name, 'lastName', p.last_name, 'nickname', p.nickname
      ) order by c.created_at, c.id)
      from private.characters c left join public.character_profiles p on p.character_id = c.id
      where c.player_id = owner_id
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
    select c.validation_status into current_status from private.characters c
      where c.id = target_id and c.player_id = owner_id;
    if not found then return jsonb_build_object('status', 'not_found'); end if;
    if not character_lifecycle.owner_can_change(current_status) then
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
  program := (sheet ->> 'programId')::uuid;
  if (operation = 'submit' or fields ? 'programId') and program is not null
    and (character_kind not in ('student', 'teacher')
      or not exists (select 1 from public.programs p where p.id = program)) then
    return jsonb_build_object('status', 'invalid_program');
  end if;
  if (operation = 'submit' or fields ? 'isScholarshipHolder')
    and character_kind <> 'student' and sheet ->> 'isScholarshipHolder' is not null then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  if operation = 'submit' then
    -- Presence rules are provisional. Editorial length thresholds are deferred.
    if exists (
      select 1 from unnest(array['firstName', 'lastName', 'personality',
        'physicalDescription', 'faceClaim', 'backstory']) as required(field)
      where coalesce(sheet ->> required.field, '') !~ '[^[:space:]]'
    ) or (character_kind = 'student' and program is null) then
      return jsonb_build_object('status', 'incomplete');
    end if;
    update private.characters set validation_status = 'submitted', current_review_id = null
      where id = target_id and player_id = owner_id;
  else
    if operation = 'create' then
      capacity := character_lifecycle.capacity(owner_id);
      if (capacity ->> 'available')::bigint <= 0 then
        return jsonb_build_object('status', 'capacity_reached');
      end if;
      insert into private.characters (player_id, kind, program_id, is_scholarship_holder)
        values (owner_id, character_kind, program, (sheet ->> 'isScholarshipHolder')::boolean)
        returning id into character_id;
    else
      update private.characters set program_id = program,
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

create function character_lifecycle.catalog_request(catalog text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  caller uuid := character_lifecycle.session_user_id();
  entries jsonb;
begin
  if caller is null then return jsonb_build_object('status', 'unauthenticated'); end if;
  if not exists (select 1 from private.players p where p.auth_user_id = caller) then
    return jsonb_build_object('status', 'player_link_required');
  end if;
  case catalog
    when 'houses' then
      select jsonb_agg(jsonb_build_object('id', id, 'slug', slug, 'name', name) order by slug)
        into entries from public.houses;
    when 'programs' then
      select jsonb_agg(jsonb_build_object('id', id, 'slug', slug, 'name', name) order by slug)
        into entries from public.programs;
    when 'clubs' then
      select jsonb_agg(jsonb_build_object(
        'id', id, 'slug', slug, 'name', name, 'memberCapacity', member_capacity) order by slug)
        into entries from public.clubs;
    else return jsonb_build_object('status', 'invalid_request');
  end case;
  return jsonb_build_object('status', 'ok', 'data', coalesce(entries, '[]'::jsonb));
end;
$$;

revoke all on function character_lifecycle.character_request(text, uuid, uuid, jsonb),
  character_lifecycle.catalog_request(text) from public, anon, authenticated, service_role;
grant execute on function character_lifecycle.character_request(text, uuid, uuid, jsonb),
  character_lifecycle.catalog_request(text) to authenticated;
alter function character_lifecycle.character_request(text, uuid, uuid, jsonb) owner to hu_character_lifecycle;
alter function character_lifecycle.catalog_request(text) owner to hu_character_lifecycle;
revoke create on schema character_lifecycle from hu_character_lifecycle;

create function public.player_characters(
  operation text, target_id uuid default null, expected_revision uuid default null, fields jsonb default null
) returns jsonb
language sql volatile security invoker set search_path = ''
begin atomic
  select character_lifecycle.character_request(operation, target_id, expected_revision, fields);
end;

create function public.player_character_catalog(catalog text) returns jsonb
language sql stable security invoker set search_path = ''
begin atomic
  select character_lifecycle.catalog_request(catalog);
end;

revoke all on function public.player_characters(text, uuid, uuid, jsonb),
  public.player_character_catalog(text) from public, anon, authenticated, service_role;
grant execute on function public.player_characters(text, uuid, uuid, jsonb),
  public.player_character_catalog(text) to authenticated;
