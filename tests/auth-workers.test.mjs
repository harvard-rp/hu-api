import { Buffer } from 'node:buffer';
import { createHmac } from 'node:crypto';
import { once } from 'node:events';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { URL } from 'node:url';

import { afterAll, beforeAll, beforeEach, expect, it, vi } from 'vitest';
import { unstable_readConfig, unstable_startWorker } from 'wrangler';

const publishableKey = 'sb_publishable_synthetic_workers_fixture';
const userId = 'a0100000-0000-4000-8000-000000000001';
const sessionId = 'a0200000-0000-4000-8000-000000000001';
const email = 'synthetic-worker-user@example.test';
const providerDetail = 'synthetic private upstream error';
const invalidToken = 'eyJhbGciOiJIUzI1NiJ9.e30.invalid';
const context = {
  playerId: 'a0300000-0000-4000-8000-000000000001',
  capabilities: [],
  characters: [],
  canAccessCampus: false,
};

const character = {
  id: 'a0400000-0000-4000-8000-000000000001',
  revision: 'a0500000-0000-4000-8000-000000000001',
  kind: 'citizen',
  validationStatus: 'draft',
  useStatus: 'active',
  createdAt: '2026-11-27T12:00:00+00:00',
  updatedAt: '2026-11-27T12:00:00+00:00',
  firstName: 'Fictional',
  lastName: null,
  nickname: null,
  houseId: null,
  programId: null,
  isScholarshipHolder: null,
  age: null,
  sexualOrientation: null,
  birthDate: null,
  birthPlace: null,
  origins: null,
  residence: null,
  financialSituation: null,
  occupation: null,
  personality: null,
  physicalDescription: null,
  faceClaim: null,
  backstory: null,
  anecdotes: null,
  contentWarnings: null,
  rpLinks: null,
};

let configDir;
let configPath;
let origin;
let validToken;
let worker;
let upstream;
let scenario;
const requests = [];

function issueFixtureToken() {
  const encode = (value) =>
    Buffer.from(JSON.stringify(value)).toString('base64url');
  const header = encode({ alg: 'HS256', typ: 'JWT' });
  const claims = encode({
    iss: `${origin}/auth/v1`,
    sub: userId,
    aud: 'authenticated',
    role: 'authenticated',
    session_id: sessionId,
    is_anonymous: false,
    exp: Math.floor(Date.now() / 1000) + 300,
  });
  const signature = createHmac('sha256', 'synthetic-workers-test-only')
    .update(`${header}.${claims}`)
    .digest('base64url');
  return `${header}.${claims}.${signature}`;
}

async function simulateSupabase(request, response) {
  const { url, method, headers } = request;
  requests.push({
    url,
    method,
    authorization: headers.authorization,
    apikey: headers.apikey,
  });
  const json = (status, body) =>
    response
      .writeHead(status, {
        'Content-Type': 'application/json',
        'X-Supabase-API-Version': '2024-01-01',
      })
      .end(JSON.stringify(body));

  if (scenario === 'auth_outage' && url === '/auth/v1/user') {
    return json(503, { message: providerDetail, email, token: validToken });
  }
  if (scenario === 'auth_disconnect' && url === '/auth/v1/user') {
    request.socket.destroy();
    return;
  }
  if (
    (scenario === 'auth_redirect' && url === '/auth/v1/user') ||
    (scenario === 'rpc_redirect' &&
      url === '/rest/v1/rpc/bootstrap_discord_player')
  ) {
    return response
      .writeHead(307, { Location: '/unexpected-redirect-target' })
      .end();
  }
  if (
    headers.apikey !== publishableKey ||
    headers.authorization !== `Bearer ${validToken}`
  ) {
    return json(403, { code: 'bad_jwt', msg: providerDetail });
  }
  if (url === '/auth/v1/user') {
    return json(200, { id: userId, is_anonymous: false, email });
  }
  if (url === '/rest/v1/rpc/current_player_context') return json(200, context);
  if (url === '/rest/v1/rpc/bootstrap_discord_player') {
    return json(200, { status: 'ok', context });
  }
  if (url === '/rest/v1/rpc/player_characters') {
    let serialized = '';
    for await (const chunk of request.setEncoding('utf8')) serialized += chunk;
    const parameters = JSON.parse(serialized);
    requests.at(-1).parameters = parameters;
    if (scenario === 'character_outage') {
      return json(503, { message: providerDetail, payload: parameters });
    }
    if (parameters.operation === 'capacity') {
      return json(200, {
        status: 'ok',
        data: { total: 5, used: 1, available: 4 },
      });
    }
    if (parameters.operation === 'create')
      return json(200, { status: 'ok', data: character });
    if (parameters.operation === 'edit')
      return json(200, { status: 'revision_conflict' });
    if (parameters.operation === 'submit')
      return json(200, { status: 'incomplete' });
  }
  return json(404, {});
}

async function startWorker(vars) {
  const logs = [];
  const runtime = await unstable_startWorker({
    config: configPath,
    bindings: Object.fromEntries(
      Object.entries(vars).map(([name, value]) => [
        name,
        { type: 'plain_text', value },
      ]),
    ),
    dev: {
      server: { hostname: '127.0.0.1', port: 0 },
      inspector: false,
      persist: false,
      watch: false,
      logLevel: 'none',
      structuredLogsHandler: (entry) => logs.push(entry),
    },
  });
  return { runtime, logs };
}

async function call(server, path, method = 'GET', token = validToken, body) {
  return globalThis.fetch(new URL(path, await server.runtime.url), {
    method,
    body,
    headers: {
      Authorization: `Bearer ${token}`,
      Cookie: 'test-only-private-cookie',
      ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
    },
  });
}

beforeAll(async () => {
  upstream = createServer(simulateSupabase).listen(0, '127.0.0.1');
  await once(upstream, 'listening');
  origin = `http://127.0.0.1:${upstream.address().port}`;
  validToken = issueFixtureToken();

  // Use the production entry point and compatibility settings in an isolated
  // config directory so developer .dev.vars or .env files are never loaded.
  const config = unstable_readConfig({ config: 'wrangler.jsonc' });
  configDir = await mkdtemp(join(tmpdir(), 'hu-api-workers-'));
  configPath = join(configDir, 'wrangler.json');
  await writeFile(
    configPath,
    JSON.stringify({
      name: config.name,
      main: config.main,
      compatibility_date: config.compatibility_date,
      compatibility_flags: config.compatibility_flags,
      send_metrics: false,
    }),
  );
  worker = await startWorker({
    SUPABASE_URL: origin,
    SUPABASE_PUBLISHABLE_KEY: publishableKey,
  });
}, 30_000);

afterAll(async () => {
  await worker?.runtime.dispose();
  if (upstream) {
    await new Promise((resolve, reject) =>
      upstream.close((error) => (error ? reject(error) : resolve())),
    );
  }
  if (configDir) await rm(configDir, { recursive: true, force: true });
}, 30_000);

beforeEach(() => {
  requests.length = 0;
  scenario = undefined;
  worker.logs.length = 0;
});

it('returns 401 after Auth rejects a JWT in workerd', async () => {
  const response = await call(worker, '/api/v1/me', 'GET', invalidToken);
  expect(response.status).toBe(401);
  expect(response.headers.get('WWW-Authenticate')).toBe('Bearer');
  expect(response.headers.get('Cache-Control')).toBe('no-store');
  expect(await response.json()).toMatchObject({
    error: { code: 'UNAUTHENTICATED' },
  });
  expect(requests.map(({ url }) => url)).toEqual(['/auth/v1/user']);
});

it.each([
  ['/api/v1/auth/bootstrap', '{"playerId":"untrusted"}'],
  ['/api/v1/auth/bootstrap?playerId=untrusted', undefined],
])(
  'rejects payloads or selectors on %s without calling the RPC',
  async (path, body) => {
    const response = await call(worker, path, 'POST', validToken, body);
    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({
      error: { code: 'INVALID_BOOTSTRAP_REQUEST' },
    });
    expect(requests.map(({ url }) => url)).toEqual(['/auth/v1/user']);
  },
);

it.each([
  ['GET', '/api/v1/me', '/rest/v1/rpc/current_player_context'],
  ['POST', '/api/v1/auth/bootstrap', '/rest/v1/rpc/bootstrap_discord_player'],
])(
  'authenticates the fixture token and serves %s %s',
  async (method, path, rpc) => {
    const response = await call(worker, path, method);
    expect(response.status).toBe(200);
    expect(response.headers.get('Cache-Control')).toBe('no-store');
    expect(await response.json()).toEqual(context);
    expect(requests).toEqual(
      [
        ['GET', '/auth/v1/user'],
        ['POST', rpc],
      ].map(([verb, url]) => ({
        method: verb,
        url,
        authorization: `Bearer ${validToken}`,
        apikey: publishableKey,
      })),
    );
  },
);

it.each([
  ['absent', {}],
  [
    'invalid',
    { SUPABASE_URL: 'not-an-origin', SUPABASE_PUBLISHABLE_KEY: publishableKey },
  ],
])(
  'reports %s configuration without calling Supabase',
  async (_name, vars) => {
    const server = await startWorker(vars);
    try {
      const response = await call(server, '/api/v1/me');
      expect(response.status).toBe(503);
      expect(requests).toEqual([]);
      await expectAuthLog(server, response, {
        reason: 'invalid_configuration',
      });
    } finally {
      await server.runtime.dispose();
    }
  },
  30_000,
);

async function expectAuthLog(server, response, authFailure) {
  const requestId = response.headers.get('X-Request-Id');
  expect(requestId).toMatch(/^[\da-f-]{36}$/);
  await vi.waitFor(() => {
    expect(server.logs.map(({ level, message }) => [level, message])).toEqual([
      ['error', JSON.stringify({ requestId, status: 503, authFailure })],
    ]);
  });
  expect(await response.json()).toEqual({
    error: {
      code: 'SERVICE_UNAVAILABLE',
      message: 'Authentication is temporarily unavailable.',
      requestId,
    },
  });
}

it('returns a generic 503 and emits only allowlisted metadata on Auth outage', async () => {
  scenario = 'auth_outage';
  const response = await call(worker, '/api/v1/me?probe=private-query-string');
  expect(response.status).toBe(503);
  expect(requests.map(({ url }) => url)).toEqual(['/auth/v1/user']);
  await expectAuthLog(worker, response, {
    reason: 'upstream_http_error',
    upstreamStatus: 503,
  });
});

it('returns a sanitized 503 when the Auth connection drops', async () => {
  scenario = 'auth_disconnect';
  const response = await call(worker, '/api/v1/me');
  expect(response.status).toBe(503);
  expect([...new Set(requests.map(({ url }) => url))]).toEqual([
    '/auth/v1/user',
  ]);
  await expectAuthLog(worker, response, { reason: 'transport_failure' });
});

it.each([
  ['auth_redirect', ['/auth/v1/user']],
  ['rpc_redirect', ['/auth/v1/user', '/rest/v1/rpc/bootstrap_discord_player']],
])(
  'fails closed on %s without forwarding credentials',
  async (redirect, paths) => {
    scenario = redirect;
    const response = await call(worker, '/api/v1/auth/bootstrap', 'POST');
    expect(response.status).toBe(503);
    expect(requests.map(({ url }) => url)).toEqual(paths);
    if (redirect === 'auth_redirect') {
      await expectAuthLog(worker, response, { reason: 'transport_failure' });
    }
  },
);

const charactersPath = '/api/v1/characters';
const detailPath = `${charactersPath}/${character.id}`;

it('routes capacity and draft creation with the caller JWT in workerd', async () => {
  const capacity = await call(worker, `${charactersPath}/capacity`);
  expect(capacity.status).toBe(200);
  expect(await capacity.json()).toEqual({ total: 5, used: 1, available: 4 });
  const fields = { kind: 'citizen', firstName: 'Fictional' };
  const response = await call(
    worker,
    charactersPath,
    'POST',
    validToken,
    JSON.stringify(fields),
  );
  expect(response.status).toBe(201);
  expect(response.headers.get('Cache-Control')).toBe('no-store');
  expect(await response.json()).toEqual(character);
  expect(requests.at(-1)).toMatchObject({
    url: '/rest/v1/rpc/player_characters',
    authorization: `Bearer ${validToken}`,
    apikey: publishableKey,
    parameters: { operation: 'create', fields },
  });
  expect(requests.at(-1).parameters).toEqual({ operation: 'create', fields });
});

it.each([
  ['POST', charactersPath, '{', 400],
  ['POST', charactersPath, '{"kind":"citizen","playerId":"untrusted"}', 400],
  ['POST', charactersPath, '{"kind":"student","houseId":null}', 400],
  [
    'PATCH',
    detailPath,
    JSON.stringify({ expectedRevision: character.revision }),
    400,
  ],
  ['GET', `${charactersPath}?playerId=untrusted`, undefined, 400],
  [
    'POST',
    charactersPath,
    JSON.stringify({ kind: 'citizen', backstory: 'a'.repeat(96 * 1024) }),
    413,
  ],
])(
  'rejects invalid %s character requests before the RPC',
  async (method, path, body, status) => {
    const response = await call(worker, path, method, validToken, body);
    expect(response.status).toBe(status);
    expect(await response.json()).toMatchObject({
      error: {
        code:
          status === 413
            ? 'CHARACTER_REQUEST_TOO_LARGE'
            : 'INVALID_CHARACTER_REQUEST',
      },
    });
    expect(requests.map(({ url }) => url)).toEqual(['/auth/v1/user']);
  },
);

it('maps stale edits and incomplete submissions without exposing the sheet', async () => {
  const edit = await call(
    worker,
    detailPath,
    'PATCH',
    validToken,
    JSON.stringify({
      expectedRevision: character.revision,
      firstName: 'Synthetic private field',
    }),
  );
  expect(edit.status).toBe(409);
  expect(await edit.json()).toMatchObject({
    error: { code: 'CHARACTER_REVISION_CONFLICT' },
  });
  expect(requests.at(-1).parameters).toEqual({
    operation: 'edit',
    target_id: character.id,
    expected_revision: character.revision,
    fields: { firstName: 'Synthetic private field' },
  });
  const submit = await call(
    worker,
    `${detailPath}/submit`,
    'POST',
    validToken,
    JSON.stringify({
      expectedRevision: character.revision,
    }),
  );
  expect(submit.status).toBe(422);
  expect(await submit.json()).toMatchObject({
    error: { code: 'CHARACTER_INCOMPLETE' },
  });
});

it('redacts character content and provider details on a Data API failure', async () => {
  scenario = 'character_outage';
  const response = await call(
    worker,
    charactersPath,
    'POST',
    validToken,
    JSON.stringify({
      kind: 'citizen',
      backstory: 'Synthetic private narrative',
    }),
  );
  expect(response.status).toBe(503);
  const requestId = response.headers.get('X-Request-Id');
  expect(await response.json()).toEqual({
    error: {
      code: 'SERVICE_UNAVAILABLE',
      message: 'The character dependency is temporarily unavailable.',
      requestId,
    },
  });
  await vi.waitFor(() =>
    expect(worker.logs.map(({ level, message }) => [level, message])).toEqual([
      ['error', JSON.stringify({ requestId, status: 503 })],
    ]),
  );
});
