import { OpenAPIHono } from '@hono/zod-openapi';
import type { Context } from 'hono';
import { secureHeaders } from 'hono/secure-headers';

import { browserCors } from './config/cors';
import { requestContext, type AppEnv } from './middleware/request-context';
import { healthRoute } from './routes/health';
import { openApiConfig, openApiRoute } from './routes/openapi';

function errorBody(c: Context<AppEnv>, code: string, message: string) {
  return { error: { code, message, requestId: c.var.requestId } };
}

export function createApp() {
  const app = new OpenAPIHono<AppEnv>();

  app.use('*', requestContext);
  app.use(
    '*',
    secureHeaders({
      contentSecurityPolicy: {
        defaultSrc: ["'none'"],
        frameAncestors: ["'none'"],
      },
      referrerPolicy: 'no-referrer',
      xFrameOptions: 'DENY',
    }),
  );

  for (const { path } of [healthRoute, openApiRoute]) {
    app.use(path, browserCors);
  }

  app.notFound((c) =>
    c.json(errorBody(c, 'NOT_FOUND', 'Route not found.'), 404),
  );
  app.onError((_error, c) =>
    c.json(
      errorBody(c, 'INTERNAL_ERROR', 'An unexpected error occurred.'),
      500,
    ),
  );

  app.openapi(healthRoute, (c) =>
    c.json({ status: 'ok', service: 'hu-api' }, 200),
  );

  app.openapi(openApiRoute, (c) =>
    c.json(app.getOpenAPIDocument(openApiConfig), 200),
  );

  return app;
}
