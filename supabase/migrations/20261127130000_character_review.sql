-- Staff review and owner history share the existing append-only review model.
create role hu_character_review nologin noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls;
grant hu_character_review to postgres with inherit false, set true;

create schema character_review;
revoke all on schema character_review from public, anon, authenticated, service_role;
grant usage, create on schema character_review to hu_character_review;
grant usage on schema private, character_lifecycle to hu_character_review;

grant execute on function character_lifecycle.session_user_id(),
  character_lifecycle.details(uuid, uuid) to hu_character_review;
grant select (id, is_anonymous, banned_until) on auth.users to hu_character_review;
grant select (id, user_id, not_after) on auth.sessions to hu_character_review;
create policy review_auth_user on auth.users for select to hu_character_review
  using (id = (select auth.uid()));
create policy review_auth_session on auth.sessions for select to hu_character_review
  using (user_id = (select auth.uid()));

grant select (id, auth_user_id) on private.players to hu_character_review;
create policy review_player_self on private.players for select to hu_character_review
  using (auth_user_id = (select auth.uid()));
grant select (staff_actor_id, capability) on private.staff_capabilities to hu_character_review;
create policy review_capability_self on private.staff_capabilities for select to hu_character_review
  using (capability = 'characters.review'
    and exists (select 1 from private.players p where p.id = staff_actor_id));

-- The underlying RLS policies limit these helpers to the current Auth subject.
create function character_review.own_player() returns uuid
language sql stable security invoker set search_path = ''
begin atomic
  select id from private.players;
end;

create function character_review.can_review() returns boolean
language sql stable security invoker set search_path = ''
begin atomic
  select exists (select 1 from private.staff_capabilities where capability = 'characters.review');
end;

revoke all on function character_review.own_player(), character_review.can_review()
  from public, anon, authenticated, service_role;
grant execute on function character_review.own_player(), character_review.can_review() to hu_character_review;

grant select (id, player_id, kind, validation_status, use_status, revision, house_id,
    house_review_id, program_id, is_scholarship_holder, created_at, updated_at),
  update (validation_status, current_review_id, house_id, house_review_id)
  on private.characters to hu_character_review;
create policy review_character_visible on private.characters for select to hu_character_review
  using (player_id = (select character_review.own_player())
    or (validation_status <> 'draft' and (select character_review.can_review())));
create policy review_character_decide on private.characters for update to hu_character_review
  using (validation_status = 'submitted'
    and player_id <> (select character_review.own_player())
    and (select character_review.can_review()))
  with check (validation_status in ('approved', 'changes_requested', 'rejected')
    and player_id <> (select character_review.own_player())
    and (select character_review.can_review()));

grant select (character_id, first_name, last_name, nickname) on public.character_profiles to hu_character_review;
grant select (character_id, age, sexual_orientation, birth_date, birth_place, origins, residence,
    financial_situation, occupation, personality, physical_description, face_claim,
    backstory, anecdotes, content_warnings, rp_links)
  on private.character_sheets to hu_character_review;
create policy review_profile_submitted on public.character_profiles for select to hu_character_review
  using (exists (select 1 from private.characters c where c.id = character_id
    and c.validation_status = 'submitted' and c.player_id <> (select character_review.own_player())));
create policy review_sheet_submitted on private.character_sheets for select to hu_character_review
  using (exists (select 1 from private.characters c where c.id = character_id
    and c.validation_status = 'submitted' and c.player_id <> (select character_review.own_player())));

grant select (id, is_active) on public.houses to hu_character_review;
create policy review_house_active on public.houses for select to hu_character_review
  using (is_active and (select character_review.can_review()));

grant select (id, character_id, decision, note, assigned_house_id, reviewed_at),
  insert (character_id, player_id, reviewer_id, decision, note, assigned_house_id, reviewed_at)
  on private.character_reviews to hu_character_review;
create policy review_history_visible on private.character_reviews for select to hu_character_review
  using (exists (select 1 from private.characters c where c.id = character_id
    and (c.player_id = (select character_review.own_player()) or c.validation_status <> 'draft')));
create policy review_history_append on private.character_reviews for insert to hu_character_review
  with check (reviewer_id = (select character_review.own_player()) and reviewer_id <> player_id
    and exists (select 1 from private.characters c where c.id = character_id
      and c.player_id = character_reviews.player_id and c.validation_status = 'submitted'));

create index characters_submitted_review_queue_idx on private.characters (id)
  where validation_status = 'submitted';
create index character_reviews_history_idx on private.character_reviews (character_id, reviewed_at, id);

create function character_review.history(target_id uuid) returns jsonb
language sql stable security invoker set search_path = ''
begin atomic
  select coalesce(jsonb_agg(jsonb_build_object(
    'decision', r.decision, 'reviewedAt', r.reviewed_at,
    'comment', r.note, 'assignedHouseId', r.assigned_house_id
  ) order by r.reviewed_at, r.id), '[]'::jsonb)
  from private.character_reviews r
  where r.character_id = target_id;
end;
revoke all on function character_review.history(uuid) from public, anon, authenticated, service_role;
grant execute on function character_review.history(uuid) to hu_character_review;

create function character_review.owner_history(target_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare owner_id uuid;
begin
  if character_lifecycle.session_user_id() is null then
    return jsonb_build_object('status', 'unauthenticated');
  end if;
  owner_id := character_review.own_player();
  if owner_id is null then return jsonb_build_object('status', 'player_link_required'); end if;
  if not exists (select 1 from private.characters c where c.id = target_id and c.player_id = owner_id) then
    return jsonb_build_object('status', 'not_found');
  end if;
  return jsonb_build_object('status', 'ok', 'data', character_review.history(target_id));
end;
$$;

create function character_review.staff_request(
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
      where c.id = target_id and c.player_id <> actor_id and c.validation_status <> 'draft';
    if not found then return jsonb_build_object('status', 'not_found'); end if;
    return jsonb_build_object('status', 'ok', 'data', entries);
  end if;

  if jsonb_typeof(decision_input) is distinct from 'object'
    or octet_length(decision_input::text) > 32768 then
    return jsonb_build_object('status', 'invalid_request');
  end if;
  if decision_input - array['decision', 'expectedRevision', 'comment', 'houseId'] <> '{}'::jsonb
    or jsonb_typeof(decision_input -> 'decision') is distinct from 'string'
    or decision_input ->> 'decision' not in ('approved', 'changes_requested', 'rejected')
    or jsonb_typeof(decision_input -> 'expectedRevision') is distinct from 'string'
    or decision_input ->> 'expectedRevision' !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    or (decision_input ? 'houseId' and (
      jsonb_typeof(decision_input -> 'houseId') <> 'string'
      or decision_input ->> 'houseId' !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    ))
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
  select c.player_id, c.kind, c.validation_status, c.revision, c.house_id, c.house_review_id into target
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
  if assigned_house is not null and (target.kind <> 'student' or outcome = 'rejected'
    or not exists (select 1 from public.houses h where h.id = assigned_house)) then
    return jsonb_build_object('status', 'invalid_house');
  end if;
  active_house := coalesce(assigned_house, target.house_id);
  if outcome = 'approved' and target.kind = 'student' and active_house is null then
    return jsonb_build_object('status', 'house_required');
  end if;

  decision_time := clock_timestamp();
  insert into private.character_reviews as r (character_id, player_id, reviewer_id, decision, note, assigned_house_id, reviewed_at)
  values (target_id, target.player_id, actor_id, outcome, player_comment, assigned_house, decision_time)
  returning r.id into review_id;
  update private.characters c set validation_status = outcome, current_review_id = review_id,
    house_id = active_house, house_review_id = case when assigned_house is not null then review_id else target.house_review_id end
    where c.id = target_id
    returning c.revision into next_revision;
  if not found then raise sqlstate 'P0901'; end if;

  return jsonb_build_object('status', 'ok', 'data', jsonb_build_object(
    'characterId', target_id, 'revision', next_revision, 'houseId', active_house,
    'review', jsonb_build_object('decision', outcome, 'reviewedAt', decision_time,
      'comment', player_comment, 'assignedHouseId', assigned_house)));
exception
  when sqlstate 'P0901' or insufficient_privilege then
    return jsonb_build_object('status', 'forbidden');
  when integrity_constraint_violation then
    return jsonb_build_object('status', 'unavailable');
end;
$$;

revoke all on function character_review.owner_history(uuid),
  character_review.staff_request(text, uuid, integer, uuid, jsonb) from public, anon, authenticated, service_role;
grant execute on function character_review.owner_history(uuid),
  character_review.staff_request(text, uuid, integer, uuid, jsonb) to authenticated;
alter function character_review.owner_history(uuid) owner to hu_character_review;
alter function character_review.staff_request(text, uuid, integer, uuid, jsonb) owner to hu_character_review;
revoke create on schema character_review from hu_character_review;

create function public.player_character_review_history(target_id uuid) returns jsonb
language sql stable security invoker set search_path = ''
begin atomic
  select character_review.owner_history(target_id);
end;

create function public.staff_character_reviews(
  operation text, target_id uuid default null, page_size integer default null,
  after_id uuid default null, decision_input jsonb default null
) returns jsonb
language sql volatile security invoker set search_path = ''
begin atomic
  select character_review.staff_request(operation, target_id, page_size, after_id, decision_input);
end;

revoke all on function public.player_character_review_history(uuid),
  public.staff_character_reviews(text, uuid, integer, uuid, jsonb) from public, anon, authenticated, service_role;
grant execute on function public.player_character_review_history(uuid),
  public.staff_character_reviews(text, uuid, integer, uuid, jsonb) to authenticated;
