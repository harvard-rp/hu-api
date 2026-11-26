import { createRoute, z } from '@hono/zod-openapi';

import { internalErrorResponse, requestIdHeader } from '../lib/http-contract';

const healthSchema = z.object({
  status: z.literal('ok'),
  service: z.literal('hu-api'),
});

export const healthRoute = createRoute({
  method: 'get',
  path: '/health',
  operationId: 'getHealth',
  summary: 'Check API liveness',
  responses: {
    200: {
      description: 'The API can serve requests.',
      headers: requestIdHeader,
      content: { 'application/json': { schema: healthSchema } },
    },
    500: internalErrorResponse,
  },
});
