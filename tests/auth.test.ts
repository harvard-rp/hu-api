import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { createApp } from '../src/app';
import type { Bindings } from '../src/config/bindings';

const origin = 'https://auth-fixture.example';
const userId = '80100000-0000-4000-8000-000000000001';
const secondId = '80100000-0000-4000-8000-000000000002';
const sessionId = '80200000-0000-4000-8000-000000000001';
const playerId = '80300000-0000-4000-8000-000000000001';
const secondPlayerId = '80300000-0000-4000-8000-000000000002';
const bindings = {
  SUPABASE_URL: origin,
  SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_synthetic_auth_fixture',
  CORS_ALLOWED_ORIGINS: 'https://campus.example',
};

function jwt(overrides: Record<string, unknown> = {}) {
  const encode = (value: object) =>
    btoa(JSON.stringify(value))
      .replaceAll('=', '')
      .replaceAll('+', '-')
      .replaceAll('/', '_');
  return [
    encode({ alg: 'HS256', typ: 'JWT' }),
    encode({
      iss: `${origin}/auth/v1`,
      sub: userId,
      aud: 'authenticated',
      role: 'authenticated',
      session_id: sessionId,
      is_anonymous: false,
      exp: Math.floor(Date.now() / 1000) + 300,
      ...overrides,
    }),
    'mock-signature',
  ].join('.');
}

function context(id = playerId) {
  return {
    playerId: id,
    capabilities: [],
    characters: [],
    canAccessCampus: false,
  };
}

function mockFetch(auth: Response, data = Response.json(context())) {
  const transport = vi.fn<typeof fetch>().mockImplementation(async (input) => {
    const target = new URL(String(input));
    if (target.origin !== origin) throw new Error('Unexpected network target');
    if (target.pathname === '/auth/v1/user') return auth;
    if (target.pathname === '/rest/v1/rpc/current_player_context') return data;
    throw new Error('Unexpected network path');
  });
  vi.stubGlobal('fetch', transport);
  return transport;
}

function getMe(authorization?: string, settings: Bindings = bindings) {
  return createApp().request(
    '/api/v1/me',
    { headers: authorization ? { Authorization: authorization } : undefined },
    settings,
  );
}

beforeEach(() => {
  vi.spyOn(console, 'info').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
});
afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe('GET /api/v1/me with simulated Auth and Data API responses', () => {
  it.each([
    undefined,
    'Basic test',
    'Bearer wrong',
    'Bearer a.b.c, Bearer d.e.f',
  ])(
    'rejects missing or malformed authorization before contacting Auth',
    async (header) => {
      const transport = mockFetch(Response.json({}));
      const response = await getMe(header);
      expect(response.status).toBe(401);
      expect(response.headers.get('WWW-Authenticate')).toBe('Bearer');
      expect(response.headers.get('Cache-Control')).toBe('no-store');
      expect(await response.json()).toMatchObject({
        error: {
          code: 'UNAUTHENTICATED',
          requestId: response.headers.get('X-Request-Id'),
        },
      });
      expect(transport).not.toHaveBeenCalled();
    },
  );

  it.each([
    ['signature', 'bad_jwt', 401],
    ['expired token', 'bad_jwt', 403],
    ['foreign project token', 'bad_jwt', 400],
    ['deleted session', 'session_not_found', 403],
    ['deleted user', 'user_not_found', 404],
  ])('fails closed when Auth rejects a %s', async (_label, code, status) => {
    const transport = mockFetch(
      Response.json(
        { code, msg: 'provider detail' },
        { status, headers: { 'X-Supabase-API-Version': '2024-01-01' } },
      ),
    );
    const response = await getMe(`Bearer ${jwt()}`);
    expect(response.status).toBe(401);
    expect(await response.text()).not.toContain('provider detail');
    expect(transport).toHaveBeenCalledTimes(1);
  });

  it.each([
    ['a mismatched issuer', { iss: 'https://foreign.example/auth/v1' }],
    ['an expired claim', { exp: 1 }],
    ['an anonymous claim', { is_anonymous: true }],
    ['a non-user role', { role: 'service_role' }],
    ['a wrong audience', { aud: 'other' }],
    ['a wrong subject', { sub: secondId }],
    ['a missing session', { session_id: undefined }],
  ])(
    'rejects %s even when the simulated upstream returns a user',
    async (_label, claims) => {
      const transport = mockFetch(
        Response.json({ id: userId, is_anonymous: false }),
      );
      expect((await getMe(`Bearer ${jwt(claims)}`)).status).toBe(401);
      expect(transport).toHaveBeenCalledTimes(1);
    },
  );

  it('rejects an anonymous Auth user', async () => {
    const transport = mockFetch(
      Response.json({ id: userId, is_anonymous: true }),
    );
    expect((await getMe(`Bearer ${jwt()}`)).status).toBe(401);
    expect(transport).toHaveBeenCalledTimes(1);
  });

  it.each([429, 500, 503])(
    'reports an Auth outage or rate limit (%i)',
    async (status) => {
      const transport = mockFetch(
        Response.json({ msg: 'provider detail' }, { status }),
      );
      expect((await getMe(`Bearer ${jwt()}`)).status).toBe(503);
      expect(transport).toHaveBeenCalledTimes(1);
    },
  );

  it('handles malformed provider data and missing configuration with a sanitized 503', async () => {
    const transport = mockFetch(
      Response.json({ id: 'not-a-user', is_anonymous: false }),
    );
    expect((await getMe(`Bearer ${jwt()}`)).status).toBe(503);
    expect((await getMe(`Bearer ${jwt()}`, {})).status).toBe(503);
    expect(transport).toHaveBeenCalledTimes(1);
  });

  it('reports transport failures without leaking credentials, cookies, or provider errors', async () => {
    const token = jwt();
    vi.stubGlobal(
      'fetch',
      vi
        .fn<typeof fetch>()
        .mockRejectedValue(new Error('upstream-private-detail')),
    );
    const response = await createApp().request(
      '/api/v1/me?playerId=untrusted-player',
      {
        headers: { Authorization: `Bearer ${token}`, Cookie: 'private-cookie' },
      },
      bindings,
    );
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({
      error: {
        code: 'SERVICE_UNAVAILABLE',
        message: 'Authentication is temporarily unavailable.',
        requestId: response.headers.get('X-Request-Id'),
      },
    });
    const entries = JSON.stringify(vi.mocked(console.error).mock.calls);
    for (const hidden of [
      token,
      'private-cookie',
      'upstream-private-detail',
      'untrusted-player',
    ]) {
      expect(entries).not.toContain(hidden);
    }
    expect(console.error).toHaveBeenCalledWith(
      JSON.stringify({
        requestId: response.headers.get('X-Request-Id'),
        status: 503,
      }),
    );
  });

  it('returns 403 for a verified user without a link', async () => {
    mockFetch(
      Response.json({ id: userId, is_anonymous: false }),
      Response.json(null),
    );
    const response = await getMe(`Bearer ${jwt()}`);
    expect(response.status).toBe(403);
    expect(await response.json()).toMatchObject({
      error: { code: 'PLAYER_LINK_REQUIRED' },
    });
    expect(response.headers.get('Cache-Control')).toBe('no-store');
  });

  it('rejects a Data API error or response outside the approved contract', async () => {
    const token = jwt();
    for (const data of [
      Response.json({ message: 'private provider detail' }, { status: 503 }),
      Response.json({ ...context(), email: 'unneeded@example.test' }),
    ]) {
      mockFetch(Response.json({ id: userId, is_anonymous: false }), data);
      const response = await getMe(`Bearer ${token}`);
      expect(response.status).toBe(503);
      expect(await response.text()).not.toMatch(
        /unneeded|private provider detail/,
      );
    }
  });

  it('keeps verified tokens and contexts isolated across concurrent requests', async () => {
    const first = jwt();
    const second = jwt({ sub: secondId });
    const requests: string[] = [];
    vi.stubGlobal(
      'fetch',
      vi.fn<typeof fetch>().mockImplementation(async (input, init) => {
        const path = new URL(String(input)).pathname;
        const headers = new Headers(init?.headers);
        const ownRequest = headers.get('Authorization') === `Bearer ${first}`;
        requests.push(path);
        expect(headers.get('apikey')).toBe(bindings.SUPABASE_PUBLISHABLE_KEY);
        expect(init?.redirect).toBe('error');
        if (path === '/auth/v1/user') {
          return Response.json({
            id: ownRequest ? userId : secondId,
            is_anonymous: false,
          });
        }
        expect(init?.body).toBe('{}');
        return Response.json(context(ownRequest ? playerId : secondPlayerId));
      }),
    );

    const app = createApp();
    const [a, b] = await Promise.all([
      app.request(
        '/api/v1/me?playerId=untrusted',
        { headers: { Authorization: `Bearer ${first}` } },
        bindings,
      ),
      app.request(
        '/api/v1/me',
        { headers: { Authorization: `Bearer ${second}` } },
        bindings,
      ),
    ]);
    expect(a.status).toBe(200);
    expect(b.status).toBe(200);
    expect(a.headers.get('Cache-Control')).toBe('no-store');
    expect(await a.json()).toEqual(context());
    expect(await b.json()).toEqual(context(secondPlayerId));
    expect(requests.sort()).toEqual([
      '/auth/v1/user',
      '/auth/v1/user',
      '/rest/v1/rpc/current_player_context',
      '/rest/v1/rpc/current_player_context',
    ]);
  });

  it('permits only an allowlisted browser origin to preflight the Authorization header', async () => {
    const app = createApp();
    const preflight = (requestedOrigin: string) => ({
      method: 'OPTIONS',
      headers: {
        Origin: requestedOrigin,
        'Access-Control-Request-Method': 'GET',
        'Access-Control-Request-Headers': 'Authorization',
      },
    });
    const allowed = await app.request(
      '/api/v1/me',
      preflight('https://campus.example'),
      bindings,
    );
    const denied = await app.request(
      '/api/v1/me',
      preflight('https://other.example'),
      bindings,
    );
    expect(allowed.status).toBe(204);
    expect(allowed.headers.get('Access-Control-Allow-Methods')).toBe('GET');
    expect(allowed.headers.get('Access-Control-Allow-Headers')).toBe(
      'Authorization',
    );
    expect(allowed.headers.get('Access-Control-Allow-Origin')).toBe(
      'https://campus.example',
    );
    expect(allowed.headers.has('Access-Control-Allow-Credentials')).toBe(false);
    expect(denied.headers.has('Access-Control-Allow-Origin')).toBe(false);
  });
});

describe('POST /api/v1/auth/bootstrap with simulated dependencies', () => {
  const path = '/api/v1/auth/bootstrap';

  function simulateBootstrap(
    data: Response,
    authResponse = Response.json({ id: userId, is_anonymous: false }),
  ) {
    const transport = vi
      .fn<typeof fetch>()
      .mockImplementation(async (input, init) => {
        const target = new URL(String(input));
        expect(target.origin).toBe(origin);
        if (target.pathname === '/auth/v1/user') return authResponse.clone();
        expect(target.pathname).toBe('/rest/v1/rpc/bootstrap_discord_player');
        expect(init?.method).toBe('POST');
        expect(init?.body).toBe('{}');
        expect(new Headers(init?.headers).get('Authorization')).toBe(
          `Bearer ${token}`,
        );
        expect(init?.redirect).toBe('error');
        return data;
      });
    const token = jwt();
    vi.stubGlobal('fetch', transport);
    return { transport, headers: { Authorization: `Bearer ${token}` } };
  }

  it('returns the shared player context with no caching', async () => {
    const { headers, transport } = simulateBootstrap(
      Response.json({ status: 'ok', context: context() }),
    );
    const response = await createApp().request(
      path,
      { method: 'POST', headers },
      bindings,
    );
    expect(response.status).toBe(200);
    expect(response.headers.get('Cache-Control')).toBe('no-store');
    expect(await response.json()).toEqual(context());
    expect(transport).toHaveBeenCalledTimes(2);
  });

  it.each([
    ['discord_identity_required', 403, 'DISCORD_IDENTITY_REQUIRED'],
    ['identity_link_conflict', 409, 'IDENTITY_LINK_CONFLICT'],
    ['unauthenticated', 401, 'UNAUTHENTICATED'],
  ])(
    'maps the database outcome %s to the public contract',
    async (status, code, error) => {
      const { headers } = simulateBootstrap(Response.json({ status }));
      const response = await createApp().request(
        path,
        { method: 'POST', headers },
        bindings,
      );
      expect(response.status).toBe(code);
      expect(response.headers.get('Cache-Control')).toBe('no-store');
      expect(await response.json()).toMatchObject({
        error: { code: error, requestId: response.headers.get('X-Request-Id') },
      });
      if (code === 401)
        expect(response.headers.get('WWW-Authenticate')).toBe('Bearer');
    },
  );

  it('fails closed for an expired token or missing Bearer credentials', async () => {
    const { transport } = simulateBootstrap(
      Response.json({ status: 'ok', context: context() }),
    );
    const app = createApp();
    expect((await app.request(path, { method: 'POST' }, bindings)).status).toBe(
      401,
    );
    const expired = await app.request(
      path,
      {
        method: 'POST',
        headers: { Authorization: `Bearer ${jwt({ exp: 1 })}` },
      },
      bindings,
    );
    expect(expired.status).toBe(401);
    expect(transport).toHaveBeenCalledTimes(1);
  });

  it('rejects caller-supplied targets without invoking the RPC', async () => {
    const { headers, transport } = simulateBootstrap(
      Response.json({ status: 'ok', context: context() }),
    );
    const app = createApp();
    const body = await app.request(
      path,
      {
        method: 'POST',
        headers,
        body: JSON.stringify({ discord_id: '123', playerId: secondPlayerId }),
      },
      bindings,
    );
    const query = await app.request(
      `${path}?playerId=${secondPlayerId}`,
      { method: 'POST', headers },
      bindings,
    );
    expect(body.status).toBe(400);
    expect(query.status).toBe(400);
    expect(transport).toHaveBeenCalledTimes(2);
    for (const [input] of transport.mock.calls)
      expect(new URL(String(input)).pathname).toBe('/auth/v1/user');
  });

  it('hides dependency errors and rejects unexpected sensitive response fields', async () => {
    const app = createApp();
    for (const upstream of [
      Response.json({ message: 'upstream-private-detail' }, { status: 500 }),
      Response.json({
        status: 'ok',
        context: { ...context(), discordId: 'upstream-private-detail' },
      }),
    ]) {
      const { headers } = simulateBootstrap(upstream);
      const response = await app.request(
        path,
        { method: 'POST', headers },
        bindings,
      );
      expect(response.status).toBe(503);
      expect(await response.text()).not.toContain('upstream-private-detail');
    }
  });

  it('permits only the needed method and header on the existing origin allowlist', async () => {
    const app = createApp();
    for (const sender of [
      'https://campus.example',
      'https://outside.example',
    ]) {
      const response = await app.request(
        path,
        {
          method: 'OPTIONS',
          headers: {
            Origin: sender,
            'Access-Control-Request-Method': 'POST',
            'Access-Control-Request-Headers': 'Authorization',
          },
        },
        bindings,
      );
      if (sender === 'https://campus.example') {
        expect(response.status).toBe(204);
        expect(response.headers.get('Access-Control-Allow-Methods')).toBe(
          'POST',
        );
        expect(response.headers.get('Access-Control-Allow-Headers')).toBe(
          'Authorization',
        );
        expect(response.headers.get('Access-Control-Allow-Origin')).toBe(
          sender,
        );
      } else {
        expect(response.headers.has('Access-Control-Allow-Origin')).toBe(false);
      }
      expect(response.headers.has('Access-Control-Allow-Credentials')).toBe(
        false,
      );
    }
  });
});
