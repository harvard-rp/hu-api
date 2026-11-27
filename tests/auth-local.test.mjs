import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import process from 'node:process';

import { afterAll, beforeAll, expect, it, vi } from 'vitest';

import { createApp } from '../src/app';

const url = 'http://127.0.0.1:54321';
const app = createApp();

function fixture() {
  const authId = randomUUID();
  return {
    authId,
    playerId: randomUUID(),
    email: `hu005-${authId}@example.test`,
    password: randomUUID(),
    discordId: (
      BigInt(`0x${authId.replaceAll('-', '').slice(0, 15)}`) + 1n
    ).toString(),
  };
}

const actor = fixture();
const teacher = fixture();
const unlinked = fixture();
const newcomer = fixture();
const activeCharacter = randomUUID();
const suspendedCharacter = randomUUID();
const submittedCharacter = randomUUID();
const actorCharacter = randomUUID();

let publishableKey;
let actorToken;
let teacherToken;
let unlinkedToken;
let newcomerToken;
let seeded = false;

function sql(command) {
  try {
    execFileSync(
      'docker',
      [
        'exec',
        '-i',
        '--user',
        'postgres',
        'supabase_db_hu-api',
        'psql',
        '-XqAt',
        '-v',
        'ON_ERROR_STOP=1',
        '-h',
        '/var/run/postgresql',
        '-U',
        'postgres',
        '-d',
        'postgres',
      ],
      { input: command, stdio: ['pipe', 'ignore', 'pipe'], timeout: 15000 },
    );
  } catch {
    throw new Error('Local Auth test database fixture query failed.');
  }
}

async function signIn({ email, password }) {
  const response = await globalThis.fetch(
    `${url}/auth/v1/token?grant_type=password`,
    {
      method: 'POST',
      headers: { apikey: publishableKey, 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, password }),
      redirect: 'error',
      signal: globalThis.AbortSignal.timeout(10000),
    },
  );
  if (!response.ok)
    throw new Error(`Local Auth fixture sign-in failed (${response.status}).`);
  const result = await response.json();
  if (typeof result.access_token !== 'string')
    throw new Error('Local Auth did not issue an access token.');
  return result.access_token;
}

function api(path, token, method = 'GET', fields) {
  return app.request(
    path,
    {
      method,
      headers: {
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...(fields ? { 'Content-Type': 'application/json' } : {}),
      },
      body: fields ? JSON.stringify(fields) : undefined,
    },
    {
      SUPABASE_URL: url,
      SUPABASE_PUBLISHABLE_KEY: publishableKey,
    },
  );
}

beforeAll(async () => {
  vi.spyOn(globalThis.console, 'info').mockImplementation(() => {});
  vi.spyOn(globalThis.console, 'error').mockImplementation(() => {});

  try {
    const endpoint = execFileSync(
      'docker',
      ['context', 'inspect', '--format', '{{.Endpoints.docker.Host}}'],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 5000 },
    ).trim();
    const localSocket = /^(unix|npipe):\/\//;
    if (
      !localSocket.test(endpoint) ||
      (process.env.DOCKER_HOST && !localSocket.test(process.env.DOCKER_HOST))
    ) {
      throw new Error('Expected a local Docker socket.');
    }
    const env = Object.fromEntries(
      Object.entries(process.env).filter(
        ([key]) => !key.startsWith('SUPABASE_'),
      ),
    );
    const status = JSON.parse(
      execFileSync('pnpm', ['exec', 'supabase', 'status', '--output', 'json'], {
        encoding: 'utf8',
        env,
        stdio: ['ignore', 'pipe', 'pipe'],
        timeout: 15000,
      }),
    );
    if (
      status.API_URL !== url ||
      !/^sb_publishable_[A-Za-z0-9_-]+$/.test(status.PUBLISHABLE_KEY ?? '')
    ) {
      throw new Error('Invalid local stack settings.');
    }
    publishableKey = status.PUBLISHABLE_KEY;
  } catch {
    throw new Error(
      'The Auth suite requires the local hu-api Supabase stack on 127.0.0.1:54321.',
    );
  }

  sql(`
    begin;
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      confirmation_token, recovery_token, email_change, email_change_token_new, email_change_token_current,
      phone_change, phone_change_token, reauthentication_token, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at
    ) values ${[actor, teacher, unlinked, newcomer]
      .map(
        ({ authId, email, password }) =>
          `('00000000-0000-0000-0000-000000000000', '${authId}', 'authenticated', 'authenticated',
        '${email}', extensions.crypt('${password}', extensions.gen_salt('bf')), now(),
        '', '', '', '', '', '', '', '', '{"provider":"email","providers":["email"]}',
        '{"capabilities":["characters.review","boosts.manage"],"role":"service_role"}', now(), now())`,
      )
      .join(', ')};
    insert into private.players (id, discord_id, auth_user_id) values
      ('${actor.playerId}', '${actor.discordId}', '${actor.authId}'),
      ('${teacher.playerId}', '${teacher.discordId}', '${teacher.authId}');
    insert into private.staff_actors (player_id) values ('${actor.playerId}');
    insert into private.staff_capabilities (staff_actor_id, capability) values ('${actor.playerId}', 'characters.review');
    insert into private.characters (id, player_id, kind, use_status) values
      ('${activeCharacter}', '${teacher.playerId}', 'teacher', 'active'),
      ('${suspendedCharacter}', '${teacher.playerId}', 'staff_member', 'suspended'),
      ('${submittedCharacter}', '${teacher.playerId}', 'student', 'active'),
      ('${actorCharacter}', '${actor.playerId}', 'citizen', 'active');
    insert into private.character_sheets (character_id, backstory) values
      ('${actorCharacter}', 'Synthetic confidential story');
    insert into private.character_reviews (character_id, player_id, reviewer_id, decision) values
      ('${activeCharacter}', '${teacher.playerId}', '${actor.playerId}', 'approved'),
      ('${suspendedCharacter}', '${teacher.playerId}', '${actor.playerId}', 'approved');
    update private.characters c set current_review_id = r.id, validation_status = 'approved'
      from private.character_reviews r where r.character_id = c.id
        and r.character_id in ('${activeCharacter}', '${suspendedCharacter}');
    update private.characters set validation_status = 'submitted' where id = '${submittedCharacter}';
    commit;
  `);
  seeded = true;

  [actorToken, teacherToken, unlinkedToken, newcomerToken] = await Promise.all([
    signIn(actor),
    signIn(teacher),
    signIn(unlinked),
    signIn(newcomer),
  ]);
}, 40000);

afterAll(() => {
  try {
    if (seeded)
      sql(`
      begin;
      update private.characters set current_review_id = null, validation_status = 'draft'
        where player_id in ('${actor.playerId}', '${teacher.playerId}');
      delete from private.character_reviews where reviewer_id = '${actor.playerId}';
      delete from private.character_sheets s using private.characters c
        where s.character_id = c.id and c.player_id in ('${actor.playerId}', '${teacher.playerId}');
      delete from public.character_profiles p using private.characters c
        where p.character_id = c.id and c.player_id in ('${actor.playerId}', '${teacher.playerId}');
      delete from private.characters where player_id in ('${actor.playerId}', '${teacher.playerId}');
      delete from private.staff_capabilities where staff_actor_id = '${actor.playerId}';
      delete from private.staff_actors where player_id = '${actor.playerId}';
      delete from private.players where id in ('${actor.playerId}', '${teacher.playerId}');
      delete from private.players where auth_user_id = '${newcomer.authId}';
      delete from auth.users where id in ('${actor.authId}', '${teacher.authId}', '${unlinked.authId}', '${newcomer.authId}');
      commit;
    `);
  } finally {
    vi.restoreAllMocks();
  }
});

it('accepts real access tokens and isolates concurrent player contexts', async () => {
  const [own, other] = await Promise.all([
    api(
      `/api/v1/me?playerId=${actor.playerId}&characterId=${actorCharacter}`,
      teacherToken,
    ),
    api('/api/v1/me', actorToken),
  ]);
  expect(own.status).toBe(200);
  expect(other.status).toBe(200);
  expect(own.headers.get('Cache-Control')).toBe('no-store');
  expect(await own.json()).toEqual({
    playerId: teacher.playerId,
    capabilities: [],
    characters: expect.arrayContaining([
      {
        id: activeCharacter,
        validationStatus: 'approved',
        useStatus: 'active',
        canAccessCampus: true,
      },
      {
        id: suspendedCharacter,
        validationStatus: 'approved',
        useStatus: 'suspended',
        canAccessCampus: false,
      },
      {
        id: submittedCharacter,
        validationStatus: 'submitted',
        useStatus: 'active',
        canAccessCampus: false,
      },
    ]),
    canAccessCampus: true,
  });
  expect(await other.json()).toEqual({
    playerId: actor.playerId,
    capabilities: ['characters.review'],
    characters: [
      {
        id: actorCharacter,
        validationStatus: 'draft',
        useStatus: 'active',
        canAccessCampus: false,
      },
    ],
    canAccessCampus: false,
  });
});

it('rejects a modified signature and treats a real unlinked user as forbidden', async () => {
  const [header, payload, signature = ''] = teacherToken.split('.');
  const invalid = `${header}.${payload}.${signature[0] === 'A' ? 'B' : 'A'}${signature.slice(1)}`;
  expect((await api('/api/v1/me')).status).toBe(401);
  expect((await api('/api/v1/me', invalid)).status).toBe(401);
  expect((await api('/api/v1/me', unlinkedToken)).status).toBe(403);
});

it('enforces the same privacy rules for direct Data API requests', async () => {
  const rpc = '/rest/v1/rpc/current_player_context';
  const request = (path, token, body = {}) =>
    globalThis.fetch(`${url}${path}`, {
      method: path === rpc ? 'POST' : 'GET',
      headers: {
        apikey: publishableKey,
        'Content-Type': 'application/json',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      ...(path === rpc ? { body: JSON.stringify(body) } : {}),
      redirect: 'error',
      signal: globalThis.AbortSignal.timeout(10000),
    });

  const allowed = await request(rpc, teacherToken);
  expect(allowed.status).toBe(200);
  const payload = await allowed.json();
  expect(payload.playerId).toBe(teacher.playerId);
  expect(payload.capabilities).toEqual([]);
  expect(payload.characters.map(({ id }) => id)).not.toContain(actorCharacter);
  expect(payload.characters).toHaveLength(3);
  expect((await request(rpc)).ok).toBe(false);
  expect(
    (await request(rpc, teacherToken, { playerId: actor.playerId })).ok,
  ).toBe(false);
  expect(
    (await request('/rest/v1/character_sheets?select=*', teacherToken)).ok,
  ).toBe(false);
  expect(
    (await request('/rest/v1/character_profiles?select=*', teacherToken)).ok,
  ).toBe(false);
  const privateSchema = await globalThis.fetch(
    `${url}/rest/v1/character_sheets?select=*`,
    {
      headers: {
        apikey: publishableKey,
        Authorization: `Bearer ${teacherToken}`,
        'Accept-Profile': 'private',
      },
      redirect: 'error',
      signal: globalThis.AbortSignal.timeout(10000),
    },
  );
  expect(privateSchema.ok).toBe(false);
});

it('re-resolves grants with the same token after an operator revokes a capability', async () => {
  const prior = await api('/api/v1/me', actorToken);
  expect(await prior.json()).toMatchObject({
    capabilities: ['characters.review'],
  });
  sql(
    `delete from private.staff_capabilities where staff_actor_id = '${actor.playerId}';`,
  );
  const next = await api('/api/v1/me', actorToken);
  expect(next.status).toBe(200);
  expect(await next.json()).toMatchObject({ capabilities: [] });
});

it('rejects a still-signed token after the local Auth session is deleted', async () => {
  expect((await api('/api/v1/me', unlinkedToken)).status).toBe(403);
  sql(`delete from auth.sessions where user_id = '${unlinked.authId}';`);
  expect((await api('/api/v1/me', unlinkedToken)).status).toBe(401);
});

function addDiscordIdentity(user, discordId = user.discordId) {
  sql(`insert into auth.identities (id, user_id, provider, provider_id, identity_data, created_at, updated_at, last_sign_in_at)
    values (gen_random_uuid(), '${user.authId}', 'discord', '${discordId}',
      jsonb_build_object('sub', '${discordId}'::text, 'provider_id', '${discordId}'::text), now(), now(), now());`);
}

const bootstrapPath = '/api/v1/auth/bootstrap';
const directBootstrapPath = '/rest/v1/rpc/bootstrap_discord_player';

function directBootstrap(
  token,
  parameters = {},
  method = 'POST',
  schema = 'public',
) {
  return globalThis.fetch(`${url}${directBootstrapPath}`, {
    method,
    headers: {
      apikey: publishableKey,
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(method === 'POST'
        ? { 'Content-Type': 'application/json', 'Content-Profile': schema }
        : {}),
    },
    ...(method === 'POST' ? { body: JSON.stringify(parameters) } : {}),
    redirect: 'error',
    signal: globalThis.AbortSignal.timeout(10000),
  });
}

it('leaves /me read-only and ignores metadata without an Auth-owned Discord identity', async () => {
  expect((await api('/api/v1/me', newcomerToken)).status).toBe(403);
  const response = await api(bootstrapPath, newcomerToken, 'POST');
  expect(response.status).toBe(403);
  expect(await response.json()).toMatchObject({
    error: { code: 'DISCORD_IDENTITY_REQUIRED' },
  });
  expect((await api('/api/v1/me', newcomerToken)).status).toBe(403);
});

it('initializes exactly one player across concurrent HTTP and direct RPC calls', async () => {
  // The password session predates the synthetic linked identity. Bootstrap
  // uses the current Auth identity, with no claim of a real Discord login.
  addDiscordIdentity(newcomer);

  const responses = await Promise.all([
    ...Array.from({ length: 4 }, () =>
      api(bootstrapPath, newcomerToken, 'POST'),
    ),
    ...Array.from({ length: 4 }, () => directBootstrap(newcomerToken)),
  ]);
  const contexts = [];
  for (const [index, response] of responses.entries()) {
    expect(response.status).toBe(200);
    const payload = await response.json();
    if (index < 4) {
      expect(response.headers.get('Cache-Control')).toBe('no-store');
      contexts.push(payload);
    } else {
      expect(payload.status).toBe('ok');
      contexts.push(payload.context);
    }
  }
  const first = contexts[0];
  expect(first).toEqual({
    playerId: expect.any(String),
    capabilities: [],
    characters: [],
    canAccessCampus: false,
  });
  for (const context of contexts) expect(context).toEqual(first);
  expect(
    await (await api(bootstrapPath, newcomerToken, 'POST')).json(),
  ).toEqual(first);
  expect(await (await api('/api/v1/me', newcomerToken)).json()).toEqual(first);
});

it('returns the same existing player context and rejects an attempt to claim that Discord account', async () => {
  addDiscordIdentity(actor);
  const current = await (await api('/api/v1/me', actorToken)).json();
  expect(await (await api(bootstrapPath, actorToken, 'POST')).json()).toEqual(
    current,
  );

  sql(
    `delete from auth.identities where user_id = '${actor.authId}' and provider = 'discord';`,
  );
  addDiscordIdentity(teacher, actor.discordId);
  const conflict = await api(bootstrapPath, teacherToken, 'POST');
  expect(conflict.status).toBe(409);
  expect(await conflict.json()).toEqual({
    error: {
      code: 'IDENTITY_LINK_CONFLICT',
      message: 'The player link requires operator review.',
      requestId: conflict.headers.get('X-Request-Id'),
    },
  });
  expect(await (await api('/api/v1/me', actorToken)).json()).toEqual(current);
});

it('blocks invalid tokens and denies RPC target selection or private schema access', async () => {
  const [header, payload, signature] = newcomerToken.split('.');
  const invalid = `${header}.${payload}.${signature[0] === 'A' ? 'B' : 'A'}${signature.slice(1)}`;
  expect((await api(bootstrapPath, invalid, 'POST')).status).toBe(401);
  expect((await directBootstrap(invalid)).ok).toBe(false);
  expect((await directBootstrap()).ok).toBe(false);
  expect(
    (await directBootstrap(newcomerToken, { player_id: actor.playerId })).ok,
  ).toBe(false);
  expect((await directBootstrap(newcomerToken, {}, 'GET')).ok).toBe(false);
  expect(
    (await directBootstrap(newcomerToken, {}, 'POST', 'account_bootstrap')).ok,
  ).toBe(false);
});

it('rejects a revoked session through both HTTP and PostgREST', async () => {
  sql(`delete from auth.sessions where user_id = '${newcomer.authId}';`);
  expect((await api(bootstrapPath, newcomerToken, 'POST')).status).toBe(401);
  const direct = await directBootstrap(newcomerToken);
  expect(await direct.json()).toEqual({ status: 'unauthenticated' });
});

const charactersPath = '/api/v1/characters';
const directCharacters = (token, parameters, schema = 'public') =>
  globalThis.fetch(`${url}/rest/v1/rpc/player_characters`, {
    method: 'POST',
    headers: {
      apikey: publishableKey,
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      'Content-Type': 'application/json',
      'Content-Profile': schema,
    },
    body: JSON.stringify(parameters),
    redirect: 'error',
    signal: globalThis.AbortSignal.timeout(10000),
  });

it('writes and submits an owned sheet through real Auth and PostgREST', async () => {
  const created = await api(charactersPath, actorToken, 'POST', {
    kind: 'staff_member',
    firstName: 'Fictional',
    backstory: 'Synthetic private narrative',
  });
  expect(created.status).toBe(201);
  expect(created.headers.get('Cache-Control')).toBe('no-store');
  const draft = await created.json();
  expect(draft).toMatchObject({
    firstName: 'Fictional',
    houseId: null,
    validationStatus: 'draft',
  });
  const details = `${charactersPath}/${draft.id}`;
  const submit = `${details}/submit`;
  const listed = await (await api(charactersPath, actorToken)).json();
  expect(listed).toContainEqual(
    expect.objectContaining({ id: draft.id, firstName: 'Fictional' }),
  );
  expect(JSON.stringify(listed)).not.toContain('Synthetic private narrative');
  expect(await (await api(details, actorToken)).json()).toEqual(draft);
  expect((await api(details, teacherToken)).status).toBe(404);
  expect(
    (
      await api(details, teacherToken, 'PATCH', {
        expectedRevision: draft.revision,
        firstName: 'Intruder',
      })
    ).status,
  ).toBe(404);
  expect(
    (
      await api(submit, actorToken, 'POST', {
        expectedRevision: draft.revision,
      })
    ).status,
  ).toBe(422);

  const edits = await Promise.all(
    ['One', 'Two'].map((lastName) =>
      api(details, actorToken, 'PATCH', {
        expectedRevision: draft.revision,
        lastName,
        personality: 'Inventive',
        physicalDescription: 'A fictional description',
        faceClaim: 'A fictional illustration',
      }),
    ),
  );
  expect(edits.map(({ status }) => status).sort()).toEqual([200, 409]);
  const conflict = await edits.find(({ status }) => status === 409).json();
  expect(conflict.error.code).toBe('CHARACTER_REVISION_CONFLICT');
  const edited = await edits.find(({ status }) => status === 200).json();
  expect(edited.revision).not.toBe(draft.revision);
  expect(await (await api(details, actorToken)).json()).toEqual(edited);
  const submitted = await api(submit, actorToken, 'POST', {
    expectedRevision: edited.revision,
  });
  expect(submitted.status).toBe(200);
  const submittedSheet = await submitted.json();
  expect(submittedSheet).toMatchObject({
    validationStatus: 'submitted',
    useStatus: 'active',
  });
  expect(
    (
      await api(submit, actorToken, 'POST', {
        expectedRevision: submittedSheet.revision,
      })
    ).status,
  ).toBe(409);
  const player = await (await api('/api/v1/me', actorToken)).json();
  expect(player.capabilities).not.toContain('boosts.manage');
  expect(player.characters).toContainEqual({
    id: draft.id,
    validationStatus: 'submitted',
    useStatus: 'active',
    canAccessCampus: false,
  });
});

it('keeps catalogs and direct character access scoped to eligible sessions', async () => {
  const clubs = await api('/api/v1/catalogs/clubs', actorToken);
  expect(clubs.status).toBe(200);
  const entries = await clubs.json();
  expect(entries).toContainEqual(
    expect.objectContaining({ slug: 'bde', memberCapacity: 10 }),
  );
  expect(entries.map(({ slug }) => slug)).not.toContain('droit');
  expect((await api('/api/v1/catalogs/houses')).status).toBe(401);
  const unlinkedSession = await signIn(unlinked);
  expect((await api('/api/v1/catalogs/programs', unlinkedSession)).status).toBe(
    403,
  );
  expect((await directCharacters(undefined, { operation: 'list' })).ok).toBe(
    false,
  );
  expect(
    (
      await directCharacters(
        actorToken,
        { operation: 'list' },
        'character_lifecycle',
      )
    ).ok,
  ).toBe(false);
  expect(
    await (
      await directCharacters(teacherToken, {
        operation: 'detail',
        target_id: actorCharacter,
      })
    ).json(),
  ).toEqual({ status: 'not_found' });
  expect(
    await (
      await directCharacters(actorToken, {
        operation: 'create',
        fields: { kind: 'student', houseId: null, playerId: teacher.playerId },
      })
    ).json(),
  ).toEqual({ status: 'invalid_request' });
  sql(`delete from auth.sessions where user_id = '${unlinked.authId}';`);
  expect(
    await (
      await directCharacters(unlinkedSession, { operation: 'list' })
    ).json(),
  ).toEqual({ status: 'unauthenticated' });
  expect((await api(charactersPath, unlinkedSession)).status).toBe(401);
});

it('grants exactly one of six concurrent requests the last remaining slot', async () => {
  const capacityPath = `${charactersPath}/capacity`;
  const capacity = await (await api(capacityPath, actorToken)).json();
  expect(capacity.available).toBeGreaterThan(0);
  for (let index = 1; index < capacity.available; index++) {
    expect(
      (await api(charactersPath, actorToken, 'POST', { kind: 'citizen' }))
        .status,
    ).toBe(201);
  }
  const requests = Array.from({ length: 6 }, (_, index) =>
    index % 2 === 0
      ? api(charactersPath, actorToken, 'POST', { kind: 'citizen' })
      : directCharacters(actorToken, {
          operation: 'create',
          fields: { kind: 'citizen' },
        }),
  );
  const outcomes = await Promise.all(
    requests.map(async (request, index) => {
      const response = await request;
      const payload = await response.json();
      if (index % 2 === 0) {
        expect([201, 409]).toContain(response.status);
        return response.status === 201 ? 'ok' : payload.error.code;
      }
      expect(response.status).toBe(200);
      return payload.status === 'capacity_reached'
        ? 'CHARACTER_CAPACITY_REACHED'
        : payload.status;
    }),
  );
  expect(outcomes.filter((outcome) => outcome === 'ok')).toHaveLength(1);
  expect(
    outcomes.filter((outcome) => outcome === 'CHARACTER_CAPACITY_REACHED'),
  ).toHaveLength(5);
  expect(await (await api(capacityPath, actorToken)).json()).toEqual({
    total: capacity.total,
    used: capacity.total,
    available: 0,
  });
}, 15000);
