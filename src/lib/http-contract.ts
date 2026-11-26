import { z } from '@hono/zod-openapi';

export const requestIdHeader = {
  'X-Request-Id': {
    description: 'Server-generated identifier for this request.',
    schema: { type: 'string' as const, format: 'uuid' },
  },
};

export const internalErrorResponse = {
  description: 'An unexpected error occurred.',
  headers: requestIdHeader,
  content: {
    'application/json': {
      schema: z.object({
        error: z.object({
          code: z.literal('INTERNAL_ERROR'),
          message: z.string(),
          requestId: z.uuid(),
        }),
      }),
    },
  },
};
