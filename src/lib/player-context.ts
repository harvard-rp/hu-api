import { z } from '@hono/zod-openapi';

import { errorResponse, requestIdHeader } from './http-contract';

export const playerContextSchema = z.strictObject({
  playerId: z.uuid(),
  capabilities: z.array(
    z.enum(['characters.review', 'boosts.manage', 'characters.reopen']),
  ),
  characters: z.array(
    z.strictObject({
      id: z.uuid(),
      validationStatus: z.enum([
        'draft',
        'submitted',
        'changes_requested',
        'approved',
        'rejected',
      ]),
      useStatus: z.enum(['active', 'suspended']),
      canAccessCampus: z.boolean(),
    }),
  ),
  canAccessCampus: z.boolean(),
});

export const cacheControlHeader = {
  'Cache-Control': {
    description: 'The response must never be stored.',
    schema: { type: 'string' as const, enum: ['no-store'] },
  },
};

export const playerContextResponse = {
  description:
    'The linked player and their current capabilities and character eligibility.',
  headers: { ...requestIdHeader, ...cacheControlHeader },
  content: { 'application/json': { schema: playerContextSchema } },
};

export const unauthenticatedResponse = {
  ...errorResponse(
    'UNAUTHENTICATED',
    'A valid Supabase Auth access token is required.',
  ),
  headers: {
    ...requestIdHeader,
    ...cacheControlHeader,
    'WWW-Authenticate': {
      schema: { type: 'string' as const, enum: ['Bearer'] },
    },
  },
};
