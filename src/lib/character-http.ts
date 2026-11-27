import { z } from '@hono/zod-openapi';
import type { Context } from 'hono';
import { bodyLimit } from 'hono/body-limit';
import { createMiddleware } from 'hono/factory';

import { authenticate } from '../middleware/authentication';
import type { AppEnv } from '../middleware/request-context';
import {
  errorBody,
  errorResponse,
  internalErrorResponse,
  requestIdHeader,
} from './http-contract';
import { cacheControlHeader, unauthenticatedResponse } from './player-context';
import { createSupabaseClient, runSupabaseQuery } from './supabase/client';

const failures = {
  invalid_request: [
    400,
    'INVALID_CHARACTER_REQUEST',
    'Check the path, query parameters and JSON fields.',
  ],
  unauthenticated: [401, 'UNAUTHENTICATED', 'A valid session is required.'],
  player_link_required: [
    403,
    'PLAYER_LINK_REQUIRED',
    'A linked player account is required.',
  ],
  not_found: [404, 'CHARACTER_NOT_FOUND', 'Character not found.'],
  forbidden: [
    403,
    'CHARACTER_REVIEW_FORBIDDEN',
    'Character review access is required.',
  ],
  not_submitted: [
    409,
    'CHARACTER_NOT_SUBMITTED',
    'The character is no longer awaiting a decision.',
  ],
  comment_required: [
    422,
    'CHARACTER_REVIEW_COMMENT_REQUIRED',
    'Supply a comment for corrections or rejection.',
  ],
  house_required: [
    422,
    'CHARACTER_HOUSE_REQUIRED',
    'Approval of a student requires a House.',
  ],
  invalid_house: [
    422,
    'INVALID_CHARACTER_HOUSE',
    'Choose an active House for an eligible student decision.',
  ],
  capacity_reached: [
    409,
    'CHARACTER_CAPACITY_REACHED',
    'All character slots are occupied.',
  ],
  character_locked: [
    409,
    'CHARACTER_LOCKED',
    'Only drafts and sheets awaiting corrections can be changed or submitted.',
  ],
  revision_conflict: [
    409,
    'CHARACTER_REVISION_CONFLICT',
    'The character changed. Reload the sheet and retry with its current revision.',
  ],
  too_large: [
    413,
    'CHARACTER_REQUEST_TOO_LARGE',
    'The JSON body exceeds 96 KiB.',
  ],
  invalid_program: [
    422,
    'INVALID_CHARACTER_PROGRAM',
    'Choose an active program permitted for this character type.',
  ],
  incomplete: [
    422,
    'CHARACTER_INCOMPLETE',
    'Complete the required fields before submitting the sheet.',
  ],
  unavailable: [
    503,
    'SERVICE_UNAVAILABLE',
    'The character dependency is temporarily unavailable.',
  ],
} as const;

const rpcResult = z.discriminatedUnion('status', [
  z.strictObject({ status: z.literal('ok'), data: z.unknown() }),
  z.strictObject({
    status: z.enum(Object.keys(failures) as (keyof typeof failures)[]),
  }),
]);

export class CharacterRequestError extends Error {
  constructor(readonly reason: keyof typeof failures) {
    super('Character request failed.');
  }

  response(c: Context<AppEnv>) {
    const [status, code, message] = failures[this.reason];
    if (status === 401) c.header('WWW-Authenticate', 'Bearer');
    return c.json(errorBody(c, code, message), status);
  }
}

function protectedError<Code extends string>(code: Code, description: string) {
  return { ...errorResponse(code, description), headers };
}

const headers = { ...requestIdHeader, ...cacheControlHeader };
export const failureResponse = <Reason extends keyof typeof failures>(
  reason: Reason,
) => protectedError(failures[reason][1], failures[reason][2]);

export const multipleFailures = (...reasons: (keyof typeof failures)[]) => ({
  description: reasons.map((reason) => failures[reason][2]).join(' '),
  headers,
  content: {
    'application/json': {
      schema: z.object({
        error: z.object({
          code: z.enum(reasons.map((reason) => failures[reason][1])),
          message: z.string(),
          requestId: z.uuid(),
        }),
      }),
    },
  },
});

export const commonErrors = {
  400: failureResponse('invalid_request'),
  401: unauthenticatedResponse,
  403: failureResponse('player_link_required'),
  503: failureResponse('unavailable'),
  500: { ...internalErrorResponse, headers },
};
export const query = z.strictObject({});
export const params = z.strictObject({ characterId: z.uuid() });
const security = [{ SupabaseBearer: [] }];
export const read = {
  security,
  middleware: [authenticate],
  request: { query },
};

const maxBodyBytes = 96 * 1024;
const requireJson = createMiddleware<AppEnv>(async (c, next) => {
  if (
    c.req.header('Content-Type')?.split(';')[0]?.trim().toLowerCase() !==
    'application/json'
  ) {
    throw new CharacterRequestError('invalid_request');
  }
  try {
    await c.req.json();
  } catch {
    throw new CharacterRequestError('invalid_request');
  }
  await next();
});
export const write = {
  security,
  middleware: [
    authenticate,
    bodyLimit({
      maxSize: maxBodyBytes,
      onError: (c) => new CharacterRequestError('too_large').response(c),
    }),
    requireJson,
  ],
};

const json = <S extends z.ZodType>(schema: S) => ({
  'application/json': { schema },
});
export const success = <S extends z.ZodType>(
  schema: S,
  description: string,
) => ({
  description,
  headers,
  content: json(schema),
});
export const body = <S extends z.ZodType>(schema: S) => ({
  content: json(schema),
  required: true,
});

export function invalid(result: { success: boolean }): undefined {
  if (!result.success) throw new CharacterRequestError('invalid_request');
}

type CharacterQuery = (client: ReturnType<typeof createSupabaseClient>) => {
  abortSignal: (
    signal: AbortSignal,
  ) => PromiseLike<{ data: unknown; error: unknown }>;
};

export async function requestCharacterData<S extends z.ZodType>(
  c: Context<AppEnv>,
  schema: S,
  select: CharacterQuery,
): Promise<z.output<S>> {
  const auth = c.var.auth;
  if (!auth) throw new CharacterRequestError('unauthenticated');
  let result;
  try {
    const client = createSupabaseClient(c.env, {
      accessToken: auth.accessToken,
    });
    result = rpcResult.parse(
      await runSupabaseQuery(() =>
        select(client).abortSignal(AbortSignal.timeout(5000)),
      ),
    );
  } catch {
    throw new CharacterRequestError('unavailable');
  }
  if (result.status !== 'ok') throw new CharacterRequestError(result.status);
  const data = schema.safeParse(result.data);
  if (!data.success) throw new CharacterRequestError('unavailable');
  return data.data;
}
