-- Preserve all prior attestations and allow uninspected external references
-- exclusively for correction requests.
alter table private.character_reviews drop constraint review_external_evidence_check;
alter table private.character_reviews add constraint review_external_evidence_check check (
  (examined_external_url is null and not external_attested)
  or (examined_external_url is not null and examined_revision is not null
    and (external_attested or decision = 'changes_requested')
    and character_lifecycle.valid_external_url(examined_external_url))
);

create or replace function character_review.history(target_id uuid) returns jsonb
language sql stable security invoker set search_path = ''
begin atomic
  select coalesce(jsonb_agg(jsonb_build_object(
    'decision', r.decision, 'reviewedAt', r.reviewed_at,
    'comment', r.note, 'assignedHouseId', r.assigned_house_id,
    'examinedRevision', r.examined_revision, 'archivedCharacter', r.archived_character,
    'externalEvidence', case when r.examined_external_url is not null then jsonb_build_object(
      'url', r.examined_external_url, 'attested', r.external_attested) end
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
  if (target.sheet_mode = 'inline' and attested)
    or (target.sheet_mode = 'external'
      and (target.external_url is null or (outcome <> 'changes_requested' and not attested))) then
    return jsonb_build_object('status', 'invalid_attestation');
  end if;
  decision_time := clock_timestamp();
  updated_refusal_count := target.refusal_count + case when outcome = 'rejected' then 1 else 0 end;
  archived := case when outcome = 'rejected' and updated_refusal_count >= 3 then decision_time end;
  insert into private.character_reviews as r (character_id, player_id, reviewer_id, decision, note, assigned_house_id, reviewed_at,
    examined_revision, examined_external_url, external_attested, archived_character)
  values (target_id, target.player_id, actor_id, outcome, player_comment, assigned_house, decision_time,
    expected_revision, case when target.sheet_mode = 'external' then target.external_url end, attested, archived is not null)
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
      'externalEvidence', case when target.sheet_mode = 'external' then jsonb_build_object('url', target.external_url, 'attested', attested) end)));
exception
  when sqlstate 'P0901' or insufficient_privilege then
    return jsonb_build_object('status', 'forbidden');
  when integrity_constraint_violation then
    return jsonb_build_object('status', 'unavailable');
end;
$$;
reset role;
revoke create on schema character_review from hu_character_review;
