import { createRoute, z, type RouteHandler } from '@hono/zod-openapi';

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

const bootstrapResult = z.discriminatedUnion('status', [
  z.strictObject({ status: z.literal('ok'), context: playerContextSchema }),
  z.strictObject({
    status: z.enum([
      'unauthenticated',
      'discord_identity_required',
      'identity_link_conflict',
    ]),
  }),
]);

const headers = { ...requestIdHeader, ...cacheControlHeader };

export const bootstrapRoute = createRoute({
  method: 'post',
  path: '/api/v1/auth/bootstrap',
  operationId: 'bootstrapDiscordPlayer',
  summary: 'Initialize or retrieve the current Discord-linked player',
  description:
    'Send a Supabase Auth access token and an empty request with no query parameters.',
  security: [{ SupabaseBearer: [] }],
  middleware: [authenticate] as const,
  responses: {
    200: playerContextResponse,
    400: {
      ...errorResponse(
        'INVALID_BOOTSTRAP_REQUEST',
        'No body or query parameters are accepted.',
      ),
      headers,
    },
    401: unauthenticatedResponse,
    403: {
      ...errorResponse(
        'DISCORD_IDENTITY_REQUIRED',
        'A verified Discord identity is required.',
      ),
      headers,
    },
    409: {
      ...errorResponse(
        'IDENTITY_LINK_CONFLICT',
        'The player link requires operator review.',
      ),
      headers,
    },
    503: {
      ...errorResponse(
        'SERVICE_UNAVAILABLE',
        'The bootstrap dependency is unavailable.',
      ),
      headers,
    },
    500: { ...internalErrorResponse, headers },
  },
});

export const postBootstrap: RouteHandler<
  typeof bootstrapRoute,
  AppEnv
> = async (c) => {
  const auth = c.var.auth;
  if (!auth) {
    c.header('WWW-Authenticate', 'Bearer');
    return c.json(
      errorBody(c, 'UNAUTHENTICATED', 'A valid access token is required.'),
      401,
    );
  }
  if (c.req.raw.body !== null || new URL(c.req.url).search !== '') {
    return c.json(
      errorBody(
        c,
        'INVALID_BOOTSTRAP_REQUEST',
        'No body or query parameters are accepted.',
      ),
      400,
    );
  }

  try {
    const client = createSupabaseClient(c.env, {
      accessToken: auth.accessToken,
    });
    const data: unknown = await runSupabaseQuery(() =>
      client
        .rpc('bootstrap_discord_player')
        .abortSignal(AbortSignal.timeout(5000)),
    );
    const result = bootstrapResult.parse(data);
    switch (result.status) {
      case 'ok':
        return c.json(result.context, 200);
      case 'unauthenticated':
        c.header('WWW-Authenticate', 'Bearer');
        return c.json(
          errorBody(c, 'UNAUTHENTICATED', 'A valid access token is required.'),
          401,
        );
      case 'discord_identity_required':
        return c.json(
          errorBody(
            c,
            'DISCORD_IDENTITY_REQUIRED',
            'A verified Discord identity is required.',
          ),
          403,
        );
      case 'identity_link_conflict':
        return c.json(
          errorBody(
            c,
            'IDENTITY_LINK_CONFLICT',
            'The player link requires operator review.',
          ),
          409,
        );
    }
  } catch {
    return c.json(
      errorBody(
        c,
        'SERVICE_UNAVAILABLE',
        'Player bootstrap is temporarily unavailable.',
      ),
      503,
    );
  }
};
