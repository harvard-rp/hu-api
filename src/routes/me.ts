import { createRoute, type RouteHandler } from '@hono/zod-openapi';

import {
  errorBody,
  errorResponse,
  internalErrorResponse,
  requestIdHeader,
} from '../lib/http-contract';
import {
  cacheControlHeader,
  playerContextResponse,
  playerContextSchema,
  unauthenticatedResponse,
} from '../lib/player-context';
import { createSupabaseClient, runSupabaseQuery } from '../lib/supabase/client';
import { authenticate } from '../middleware/authentication';
import type { AppEnv } from '../middleware/request-context';

export const meRoute = createRoute({
  method: 'get',
  path: '/api/v1/me',
  operationId: 'getCurrentPlayer',
  summary: 'Get the current player authorization context',
  security: [{ SupabaseBearer: [] }],
  middleware: [authenticate] as const,
  responses: {
    200: playerContextResponse,
    401: unauthenticatedResponse,
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
