import { createRoute, z } from '@hono/zod-openapi';

import { internalErrorResponse, requestIdHeader } from '../lib/http-contract';

export const openApiConfig = {
  openapi: '3.0.3',
  info: {
    title: 'Harvard University RP API',
    version: '0.1.0',
  },
};

export const openApiRoute = createRoute({
  method: 'get',
  path: '/openapi.json',
  operationId: 'getOpenApiDocument',
  summary: 'Get the OpenAPI document',
  responses: {
    200: {
      description: 'The OpenAPI document for the public endpoints.',
      headers: requestIdHeader,
      content: {
        'application/json': {
          schema: z.looseObject({
            openapi: z.string(),
            info: z.looseObject({ title: z.string(), version: z.string() }),
            paths: z.looseObject({}),
          }),
        },
      },
    },
    500: internalErrorResponse,
  },
});
