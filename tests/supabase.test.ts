import { afterEach, describe, expect, it, vi } from 'vitest';

import { createApp } from '../src/app';
import {
  createSupabaseClient,
  runSupabaseQuery,
  SupabaseQueryError,
} from '../src/lib/supabase/client';
import {
  readSupabaseConfig,
  SupabaseConfigurationError,
} from '../src/lib/supabase/config';

const url = 'https://campus.example';
const publishableKey = ['sb_publishable', 'synthetic-test-key'].join('_');
const bindings = {
  SUPABASE_URL: url,
  SUPABASE_PUBLISHABLE_KEY: publishableKey,
};

function testJwt(subject: string) {
  const segment = (value: object) =>
    btoa(JSON.stringify(value))
      .replaceAll('=', '')
      .replaceAll('+', '-')
      .replaceAll('/', '_');
  return `${segment({ alg: 'HS256', typ: 'JWT' })}.${segment({ sub: subject })}.test-signature`;
}

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe('Supabase configuration', () => {
  it.each([
    url,
    'http://127.0.0.1:54321',
    'http://localhost:54321',
    'http://[::1]:54321',
  ])('accepts a publishable key and the endpoint %s', (endpoint) => {
    expect(
      readSupabaseConfig({ ...bindings, SUPABASE_URL: `${endpoint}/` }),
    ).toEqual({
      url: endpoint,
      publishableKey,
    });
  });

  it.each([
    undefined,
    {},
    { SUPABASE_URL: url },
    { SUPABASE_PUBLISHABLE_KEY: publishableKey },
  ])('fails cleanly when configuration is absent or incomplete', (settings) => {
    expect(() => createSupabaseClient(settings)).toThrow(
      SupabaseConfigurationError,
    );
  });

  it.each([
    'not-a-url',
    'http://campus.example',
    'https://remote.example/rest/v1',
    'https://remote.example?unexpected=1',
    'https://remote.example#fragment',
    'https://test:input@remote.example',
  ])('rejects an invalid API base URL', (endpoint) => {
    expect(() =>
      createSupabaseClient({ ...bindings, SUPABASE_URL: endpoint }),
    ).toThrow('Supabase configuration is missing or invalid.');
  });

  it.each([
    '',
    testJwt('legacy-key'),
    ['sb_secret', 'synthetic-restricted-key'].join('_'),
  ])('rejects a non-publishable key', (key) => {
    expect(() =>
      createSupabaseClient({ ...bindings, SUPABASE_PUBLISHABLE_KEY: key }),
    ).toThrow(SupabaseConfigurationError);
  });
});

describe('Supabase queries', () => {
  it('uses an injected fetch with the expected URL and API key', async () => {
    const transport = vi
      .fn<typeof fetch>()
      .mockImplementation(async () => Response.json([{ id: 1 }]));
    const client = createSupabaseClient(bindings, { fetch: transport });

    expect(transport).not.toHaveBeenCalled();
    await expect(
      runSupabaseQuery(() => client.from('fixtures').select('id')),
    ).resolves.toEqual([{ id: 1 }]);

    const [input, init] = transport.mock.calls[0]!;
    expect(String(input)).toBe(`${url}/rest/v1/fixtures?select=id`);
    expect(new Headers(init?.headers).get('apikey')).toBe(publishableKey);
    expect(init?.redirect).toBe('manual');
  });

  it('isolates concurrent user JWTs and keeps anonymous calls independent', async () => {
    const firstToken = testJwt('first-test-user');
    const secondToken = testJwt('second-test-user');
    const transport = vi
      .fn<typeof fetch>()
      .mockImplementation(async () => Response.json([]));
    const first = createSupabaseClient(bindings, {
      accessToken: firstToken,
      fetch: transport,
    });
    const second = createSupabaseClient(bindings, {
      accessToken: secondToken,
      fetch: transport,
    });
    const anonymous = createSupabaseClient(bindings, { fetch: transport });

    await Promise.all([
      runSupabaseQuery(() => first.from('first_fixture').select()),
      runSupabaseQuery(() => second.from('second_fixture').select()),
      runSupabaseQuery(() => anonymous.from('anonymous_fixture').select()),
    ]);

    const requests = new Map(
      transport.mock.calls.map(([input, init]) => [
        new URL(String(input)).pathname,
        new Headers(init?.headers).get('Authorization'),
      ]),
    );
    expect(requests.get('/rest/v1/first_fixture')).toBe(`Bearer ${firstToken}`);
    expect(requests.get('/rest/v1/second_fixture')).toBe(
      `Bearer ${secondToken}`,
    );
    expect(requests.get('/rest/v1/anonymous_fixture')).toBe(
      `Bearer ${publishableKey}`,
    );
    expect(() => first.auth.getSession()).toThrow();
  });

  it('rejects malformed user tokens without including the input in the error', () => {
    expect(() =>
      createSupabaseClient(bindings, {
        accessToken: 'invalid-sensitive-input',
      }),
    ).toThrow(/^Invalid Supabase user access token\.$/);
  });

  it('normalizes network and upstream errors without logging credentials', async () => {
    const log = vi.spyOn(console, 'error').mockImplementation(() => {});
    const warning = vi.spyOn(console, 'warn').mockImplementation(() => {});
    const transport = vi
      .fn<typeof fetch>()
      .mockRejectedValueOnce(new Error(publishableKey))
      .mockResolvedValueOnce(
        Response.json({ message: publishableKey }, { status: 403 }),
      );
    const client = createSupabaseClient(bindings, { fetch: transport });
    const query = () => client.from('fixtures').select().retry(false);

    for (let attempt = 0; attempt < 2; attempt++) {
      const failure = runSupabaseQuery(query);
      await expect(failure).rejects.toBeInstanceOf(SupabaseQueryError);
      await expect(failure).rejects.toThrow(/^Supabase query failed\.$/);
      await expect(failure).rejects.not.toHaveProperty('cause');
    }
    expect(log).not.toHaveBeenCalled();
    expect(warning).not.toHaveBeenCalled();
  });
});

it('serves health without reading Supabase bindings or making an upstream request', async () => {
  const transport = vi.fn<typeof fetch>();
  vi.stubGlobal('fetch', transport);
  vi.spyOn(console, 'info').mockImplementation(() => {});
  const response = await createApp().request(
    '/health',
    {},
    {
      get SUPABASE_URL(): string {
        throw new Error('Health must not read Supabase configuration.');
      },
    },
  );

  expect(response.status).toBe(200);
  expect(await response.json()).toEqual({ status: 'ok', service: 'hu-api' });
  expect(transport).not.toHaveBeenCalled();
});
