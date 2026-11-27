import { OpenAPIHono } from '@hono/zod-openapi';
import { secureHeaders } from 'hono/secure-headers';

import {
  authenticatedBrowserCors,
  bootstrapBrowserCors,
  browserCors,
} from './config/cors';
import { errorBody } from './lib/http-contract';
import { noStore } from './middleware/authentication';
import { requestContext, type AppEnv } from './middleware/request-context';
import { bootstrapRoute, postBootstrap } from './routes/bootstrap';
import { healthRoute } from './routes/health';
import { getMe, meRoute } from './routes/me';
import { openApiConfig, openApiRoute } from './routes/openapi';

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
  app.use(meRoute.path, noStore, authenticatedBrowserCors);
  app.use(bootstrapRoute.path, noStore, bootstrapBrowserCors);

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
    c.json({ status: 'ok', service: 'hu-api' } as const, 200),
  );

  app.openapi(openApiRoute, (c) =>
    c.json(app.getOpenAPIDocument(openApiConfig), 200),
  );
  app.openAPIRegistry.registerComponent('securitySchemes', 'SupabaseBearer', {
    type: 'http',
    scheme: 'bearer',
    bearerFormat: 'JWT',
  });
  app.openapi(meRoute, getMe);
  app.openapi(bootstrapRoute, postBootstrap);

  return app;
}
