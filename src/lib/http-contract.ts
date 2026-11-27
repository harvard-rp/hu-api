import { z } from '@hono/zod-openapi';
import type { Context } from 'hono';

import type { AppEnv } from '../middleware/request-context';

export function errorBody<Code extends string>(
  c: Context<AppEnv>,
  code: Code,
  message: string,
) {
  return { error: { code, message, requestId: c.var.requestId } };
}

export const requestIdHeader = {
  'X-Request-Id': {
    description: 'Server-generated identifier for this request.',
    schema: { type: 'string' as const, format: 'uuid' },
  },
};

export const errorResponse = <Code extends string>(
  code: Code,
  description: string,
) => ({
  description,
  headers: requestIdHeader,
  content: {
    'application/json': {
      schema: z.object({
        error: z.object({
          code: z.literal(code),
          message: z.string(),
          requestId: z.uuid(),
        }),
      }),
    },
  },
});

export const internalErrorResponse = errorResponse(
  'INTERNAL_ERROR',
  'An unexpected error occurred.',
);
