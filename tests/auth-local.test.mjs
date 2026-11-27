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
const activeCharacter = randomUUID();
const suspendedCharacter = randomUUID();
const submittedCharacter = randomUUID();
const actorCharacter = randomUUID();

let publishableKey;
let actorToken;
let teacherToken;
let unlinkedToken;
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

function api(path, token) {
  return app.request(
    path,
    { headers: token ? { Authorization: `Bearer ${token}` } : {} },
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
    ) values ${[actor, teacher, unlinked]
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

  [actorToken, teacherToken, unlinkedToken] = await Promise.all([
    signIn(actor),
    signIn(teacher),
    signIn(unlinked),
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
      delete from private.character_sheets where character_id = '${actorCharacter}';
      delete from private.characters where player_id in ('${actor.playerId}', '${teacher.playerId}');
      delete from private.staff_capabilities where staff_actor_id = '${actor.playerId}';
      delete from private.staff_actors where player_id = '${actor.playerId}';
      delete from private.players where id in ('${actor.playerId}', '${teacher.playerId}');
      delete from auth.users where id in ('${actor.authId}', '${teacher.authId}', '${unlinked.authId}');
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
