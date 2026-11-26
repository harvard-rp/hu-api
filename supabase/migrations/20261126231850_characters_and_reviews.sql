create type private.character_kind as enum ('student', 'teacher', 'staff_member', 'citizen');
create type private.validation_status as enum ('draft', 'submitted', 'changes_requested', 'approved', 'rejected');
create type private.character_use_status as enum ('active', 'suspended');

create table private.characters (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references private.players(id),
  kind private.character_kind not null,
  validation_status private.validation_status not null default 'draft',
  use_status private.character_use_status not null default 'active',
  current_review_id uuid,
  house_id uuid references public.houses(id),
  house_review_id uuid,
  program_id uuid references public.programs(id),
  is_scholarship_holder boolean,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, player_id),
  constraint characters_review_required check (
    (validation_status in ('changes_requested', 'approved', 'rejected'))
      = (current_review_id is not null)
  ),
  constraint characters_house_assignment_required check (
    (house_id is null) = (house_review_id is null)
  ),
  constraint characters_approved_student_house check (
    kind <> 'student' or validation_status <> 'approved' or house_id is not null
  )
);

-- Only these basic RP fields are candidates for future public presentation.
create table public.character_profiles (
  character_id uuid primary key references private.characters(id),
  first_name text check (btrim(first_name) <> ''),
  last_name text check (btrim(last_name) <> ''),
  nickname text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table private.character_sheets (
  character_id uuid primary key references private.characters(id),
  age smallint check (age >= 0),
  sexual_orientation text,
  birth_date date,
  birth_place text,
  origins text,
  residence text,
  financial_situation text,
  occupation text,
  personality text,
  physical_description text,
  face_claim text,
  backstory text,
  anecdotes text,
  content_warnings text[],
  rp_links text[],
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table private.character_reviews (
  id uuid primary key default gen_random_uuid(),
  character_id uuid not null,
  player_id uuid not null,
  reviewer_id uuid not null references private.staff_actors(player_id),
  decision private.validation_status not null check (decision in ('changes_requested', 'approved', 'rejected')),
  note text,
  assigned_house_id uuid references public.houses(id),
  reviewed_at timestamptz not null default now(),
  foreign key (character_id, player_id) references private.characters(id, player_id),
  constraint character_reviews_no_self_review check (reviewer_id <> player_id),
  unique (character_id, id, decision),
  unique (character_id, id, assigned_house_id)
);

alter table private.characters
  add constraint characters_current_review_fk
    foreign key (id, current_review_id, validation_status)
      references private.character_reviews(character_id, id, decision),
  add constraint characters_house_review_fk
    foreign key (id, house_review_id, house_id)
      references private.character_reviews(character_id, id, assigned_house_id);

create index characters_player_idx on private.characters (player_id);
create index characters_house_idx on private.characters (house_id) where house_id is not null;
create index characters_program_idx on private.characters (program_id) where program_id is not null;
create index character_reviews_reviewer_idx on private.character_reviews (reviewer_id);
create index character_reviews_house_idx on private.character_reviews (assigned_house_id)
  where assigned_house_id is not null;

create trigger characters_set_updated_at before update on private.characters
  for each row execute function private.set_updated_at();
create trigger character_profiles_set_updated_at before update on public.character_profiles
  for each row execute function private.set_updated_at();
create trigger character_sheets_set_updated_at before update on private.character_sheets
  for each row execute function private.set_updated_at();

alter table private.characters enable row level security;
alter table public.character_profiles enable row level security;
alter table private.character_sheets enable row level security;
alter table private.character_reviews enable row level security;

revoke all on private.characters, public.character_profiles, private.character_sheets,
  private.character_reviews from public, anon, authenticated, service_role;
