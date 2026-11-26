import { createMiddleware } from 'hono/factory';
import { z } from 'zod';

export type Bindings = {
  CORS_ALLOWED_ORIGINS?: string;
};

const browserOrigin = z.string().refine((value) => {
  const url = URL.parse(value);
  return (
    url?.origin === value &&
    (url.protocol === 'http:' || url.protocol === 'https:')
  );
});

const allowedOrigins = z.array(browserOrigin);

export const browserCors = createMiddleware<{ Bindings: Bindings }>(
  async (c, next) => {
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
        return c.body(null, 204);
      }
    }

    await next();
  },
);
