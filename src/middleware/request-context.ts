import { createMiddleware } from 'hono/factory';

import type { Bindings } from '../config/bindings';

export type AppEnv = {
  Bindings: Bindings;
  Variables: { requestId: string };
};

export const requestContext = createMiddleware<AppEnv>(async (c, next) => {
  const requestId = crypto.randomUUID();

  c.set('requestId', requestId);
  c.header('X-Request-Id', requestId);

  await next();

  const status = c.res.status;
  const entry = JSON.stringify({ requestId, status });

  if (status >= 500) {
    console.error(entry);
  } else {
    console.info(entry);
  }
});
