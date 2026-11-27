import SwaggerParser from '@apidevtools/swagger-parser';
import type { OpenAPIV3 } from 'openapi-types';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { createApp } from '../src/app';

const allowedOrigin = 'https://campus.example';
const corsBindings = {
  CORS_ALLOWED_ORIGINS: `http://localhost:5173, ${allowedOrigin}`,
};

beforeEach(() => {
  vi.spyOn(console, 'info').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe('hu-api', () => {
  it('returns the public liveness contract', async () => {
    const response = await createApp().request('/health');

    expect(response.status).toBe(200);
    expect(response.headers.get('Content-Type')).toMatch(/^application\/json/);
    expect(await response.json()).toEqual({ status: 'ok', service: 'hu-api' });
  });

  it('generates its own request IDs and sends API security headers', async () => {
    const app = createApp();
    const request = { headers: { 'X-Request-Id': 'untrusted-client-value' } };
    const first = await app.request('/health', request);
    const second = await app.request('/health', request);
    const requestId = first.headers.get('X-Request-Id');

    expect(requestId).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
    );
    expect(second.headers.get('X-Request-Id')).not.toBe(requestId);
    expect(first.headers.get('X-Content-Type-Options')).toBe('nosniff');
    expect(first.headers.get('X-Frame-Options')).toBe('DENY');
    expect(first.headers.get('Referrer-Policy')).toBe('no-referrer');
    expect(first.headers.get('Content-Security-Policy')).toContain(
      "default-src 'none'",
    );
    expect(console.info).toHaveBeenCalledWith(
      JSON.stringify({ requestId, status: 200 }),
    );
  });

  it('returns the JSON error contract for unregistered routes', async () => {
    const response = await createApp().request('/api/v1/missing');

    expect(response.status).toBe(404);
    expect(response.headers.get('Content-Type')).toMatch(/^application\/json/);
    expect(response.headers.get('X-Request-Id')).toBeTruthy();
    expect(await response.json()).toEqual({
      error: {
        code: 'NOT_FOUND',
        message: 'Route not found.',
        requestId: response.headers.get('X-Request-Id'),
      },
    });
  });

  it('serves a valid OpenAPI document describing public and protected endpoints', async () => {
    const response = await createApp().request('/openapi.json');

    expect(response.status).toBe(200);
    expect(response.headers.get('Content-Type')).toMatch(/^application\/json/);
    const document = await response.json<OpenAPIV3.Document>();
    await expect(SwaggerParser.validate(document)).resolves.toBeDefined();
    expect(document.openapi).toBe('3.0.3');
    expect(Object.keys(document.paths).sort()).toEqual([
      '/api/v1/auth/bootstrap',
      '/api/v1/me',
      '/health',
      '/openapi.json',
    ]);
    expect(document.paths['/health']?.get?.responses).toHaveProperty('200');
    expect(document.paths['/openapi.json']?.get?.responses).toHaveProperty(
      '200',
    );
    expect(document.paths['/api/v1/me']?.get?.security).toEqual([
      { SupabaseBearer: [] },
    ]);
    expect(
      Object.keys(document.paths['/api/v1/me']?.get?.responses ?? {}).sort(),
    ).toEqual(['200', '401', '403', '500', '503']);
  });

  it.each([
    ['an origin without configuration', allowedOrigin, undefined],
    [
      'a different host',
      'https://campus.example.attacker.example',
      corsBindings,
    ],
    ['a different scheme', 'http://campus.example', corsBindings],
    ['a null origin', 'null', corsBindings],
    ['a wildcard setting', allowedOrigin, { CORS_ALLOWED_ORIGINS: '*' }],
    [
      'a partially invalid list',
      allowedOrigin,
      { CORS_ALLOWED_ORIGINS: `${allowedOrigin},*` },
    ],
  ])('denies cross-origin access for %s', async (_label, origin, bindings) => {
    const response = await createApp().request(
      '/health',
      { headers: { Origin: origin } },
      bindings,
    );

    expect(response.status).toBe(200);
    expect(response.headers.has('Access-Control-Allow-Origin')).toBe(false);
    expect(response.headers.has('Access-Control-Allow-Credentials')).toBe(
      false,
    );
  });

  it('allows exact configured origins and exposes request IDs on both public routes', async () => {
    const app = createApp();

    for (const path of ['/health', '/openapi.json']) {
      const response = await app.request(
        path,
        { headers: { Origin: allowedOrigin } },
        corsBindings,
      );

      expect(response.headers.get('Access-Control-Allow-Origin')).toBe(
        allowedOrigin,
      );
      expect(response.headers.get('Access-Control-Expose-Headers')).toBe(
        'X-Request-Id',
      );
      expect(response.headers.get('Vary')).toContain('Origin');
      expect(response.headers.has('Access-Control-Allow-Credentials')).toBe(
        false,
      );
    }
  });

  it('limits preflight to GET and leaves unknown paths as JSON 404s', async () => {
    const app = createApp();
    const preflight = {
      method: 'OPTIONS',
      headers: {
        Origin: allowedOrigin,
        'Access-Control-Request-Method': 'GET',
        'Access-Control-Request-Headers': 'Authorization',
      },
    };

    const response = await app.request('/health', preflight, corsBindings);
    const missing = await app.request('/missing', preflight, corsBindings);

    expect(response.status).toBe(204);
    expect(response.headers.get('Access-Control-Allow-Origin')).toBe(
      allowedOrigin,
    );
    expect(response.headers.get('Access-Control-Allow-Methods')).toBe('GET');
    expect(response.headers.has('Access-Control-Allow-Headers')).toBe(false);
    expect(missing.status).toBe(404);
    expect(missing.headers.has('Access-Control-Allow-Origin')).toBe(false);
  });

  it('redacts internal errors in both the response and the request log', async () => {
    const app = createApp();
    app.get('/throws', () => {
      throw new Error('Private test error detail');
    });

    const response = await app.request('/throws?private=query', {
      headers: {
        'X-Request-Id': 'private-client-id',
        Authorization: 'private-test-header',
      },
    });

    expect(response.status).toBe(500);
    expect(response.headers.get('X-Content-Type-Options')).toBe('nosniff');
    const requestId = response.headers.get('X-Request-Id');
    expect(requestId).toBeTruthy();
    expect(await response.json()).toEqual({
      error: {
        code: 'INTERNAL_ERROR',
        message: 'An unexpected error occurred.',
        requestId,
      },
    });
    expect(console.error).toHaveBeenCalledExactlyOnceWith(
      JSON.stringify({ requestId, status: 500 }),
    );
    expect(console.info).not.toHaveBeenCalled();
  });

  it('uses the same error handler if OpenAPI generation fails', async () => {
    const app = createApp();
    vi.spyOn(app, 'getOpenAPIDocument').mockImplementation(() => {
      throw new Error('Private registry error detail');
    });

    const response = await app.request('/openapi.json');

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({
      error: {
        code: 'INTERNAL_ERROR',
        message: 'An unexpected error occurred.',
        requestId: response.headers.get('X-Request-Id'),
      },
    });
  });
});
