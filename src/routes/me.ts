import { createRoute, z, type RouteHandler } from '@hono/zod-openapi';

import {
  errorBody,
  errorResponse,
  internalErrorResponse,
  requestIdHeader,
} from '../lib/http-contract';
import { createSupabaseClient, runSupabaseQuery } from '../lib/supabase/client';
import { authenticate } from '../middleware/authentication';
import type { AppEnv } from '../middleware/request-context';

const playerContextSchema = z.strictObject({
  playerId: z.uuid(),
  capabilities: z.array(z.enum(['characters.review', 'boosts.manage'])),
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

const cacheControlHeader = {
  'Cache-Control': {
    description: 'The response must never be stored.',
    schema: { type: 'string' as const, enum: ['no-store'] },
  },
};

export const meRoute = createRoute({
  method: 'get',
  path: '/api/v1/me',
  operationId: 'getCurrentPlayer',
  summary: 'Get the current player authorization context',
  security: [{ SupabaseBearer: [] }],
  middleware: [authenticate] as const,
  responses: {
    200: {
      description:
        'The linked player and their current capabilities and character eligibility.',
      headers: { ...requestIdHeader, ...cacheControlHeader },
      content: { 'application/json': { schema: playerContextSchema } },
    },
    401: {
      ...errorResponse(
        'UNAUTHENTICATED',
        'A valid Supabase Auth access token is required.',
      ),
      headers: {
        ...requestIdHeader,
        ...cacheControlHeader,
        'WWW-Authenticate': { schema: { type: 'string', enum: ['Bearer'] } },
      },
    },
    403: {
      ...errorResponse(
        'PLAYER_LINK_REQUIRED',
        'No player is linked to the authenticated account.',
      ),
      headers: { ...requestIdHeader, ...cacheControlHeader },
    },
    503: {
      ...errorResponse(
        'SERVICE_UNAVAILABLE',
        'The authentication or player context dependency is unavailable.',
      ),
      headers: { ...requestIdHeader, ...cacheControlHeader },
    },
    500: {
      ...internalErrorResponse,
      headers: { ...requestIdHeader, ...cacheControlHeader },
    },
  },
});

export const getMe: RouteHandler<typeof meRoute, AppEnv> = async (c) => {
  const auth = c.var.auth;
  if (!auth) {
    c.header('WWW-Authenticate', 'Bearer');
    return c.json(
      errorBody(c, 'UNAUTHENTICATED', 'A valid access token is required.'),
      401,
    );
  }

  try {
    const client = createSupabaseClient(c.env, {
      accessToken: auth.accessToken,
    });
    const context: unknown = await runSupabaseQuery(() =>
      client
        .rpc('current_player_context')
        .abortSignal(AbortSignal.timeout(5000)),
    );
    if (context === null) {
      return c.json(
        errorBody(
          c,
          'PLAYER_LINK_REQUIRED',
          'A linked player account is required.',
        ),
        403,
      );
    }
    return c.json(playerContextSchema.parse(context), 200);
  } catch {
    return c.json(
      errorBody(
        c,
        'SERVICE_UNAVAILABLE',
        'Player context is temporarily unavailable.',
      ),
      503,
    );
  }
};
