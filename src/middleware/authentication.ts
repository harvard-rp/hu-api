import { createMiddleware } from 'hono/factory';

import { errorBody } from '../lib/http-contract';
import { verifyAccessToken } from '../lib/supabase/auth';
import type { AppEnv } from './request-context';

export const noStore = createMiddleware<AppEnv>(async (c, next) => {
  c.header('Cache-Control', 'no-store');
  await next();
});

export const authenticate = createMiddleware<AppEnv>(async (c, next) => {
  const result = await verifyAccessToken(c.env, c.req.header('Authorization'));
  if (result.status === 'unavailable') {
    return c.json(
      errorBody(
        c,
        'SERVICE_UNAVAILABLE',
        'Authentication is temporarily unavailable.',
      ),
      503,
    );
  }
  if (result.status !== 'verified') {
    c.header('WWW-Authenticate', 'Bearer');
    return c.json(
      errorBody(c, 'UNAUTHENTICATED', 'A valid access token is required.'),
      401,
    );
  }
  c.set('auth', result.identity);
  await next();
});
