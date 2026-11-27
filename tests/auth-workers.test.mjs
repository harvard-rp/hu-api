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

function simulateSupabase(request, response) {
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
