import { createMiddleware } from 'hono/factory';
import { z } from 'zod';

import type { Bindings } from './bindings';

const browserOrigin = z.string().refine((value) => {
  const url = URL.parse(value);
  return (
    url?.origin === value &&
    (url.protocol === 'http:' || url.protocol === 'https:')
  );
});

const allowedOrigins = z.array(browserOrigin);

function createBrowserCors(allowAuthorization = false) {
  return createMiddleware<{ Bindings: Bindings }>(async (c, next) => {
    c.header('Vary', 'Origin', { append: true });

    const origin = c.req.header('Origin');
    const setting = c.env?.CORS_ALLOWED_ORIGINS?.trim();
    const origins = allowedOrigins.safeParse(
      setting ? setting.split(',').map((entry) => entry.trim()) : [],
    );

    if (origin && origins.success && origins.data.includes(origin)) {
      c.header('Access-Control-Allow-Origin', origin);
      c.header('Access-Control-Expose-Headers', 'X-Request-Id');

      if (
        c.req.method === 'OPTIONS' &&
        c.req.header('Access-Control-Request-Method')
      ) {
        c.header('Access-Control-Allow-Methods', 'GET');
        if (allowAuthorization)
          c.header('Access-Control-Allow-Headers', 'Authorization');
        return c.body(null, 204);
      }
    }

    await next();
  });
}

export const browserCors = createBrowserCors();
export const authenticatedBrowserCors = createBrowserCors(true);
