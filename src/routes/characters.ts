import { createRoute, z, type OpenAPIHono } from '@hono/zod-openapi';
import type { Context } from 'hono';
import { bodyLimit } from 'hono/body-limit';
import { createMiddleware } from 'hono/factory';

import {
  characterCapacity,
  characterCatalog,
  characterDetail,
  characterList,
  clubCatalog,
  createDraft,
  editDraft,
  submitDraft,
} from '../lib/character-sheet';
import {
  errorBody,
  errorResponse,
  internalErrorResponse,
  requestIdHeader,
} from '../lib/http-contract';
import {
  cacheControlHeader,
  unauthenticatedResponse,
} from '../lib/player-context';
import { createSupabaseClient, runSupabaseQuery } from '../lib/supabase/client';
import type { Database } from '../lib/supabase/database.types';
import { authenticate, noStore } from '../middleware/authentication';
import type { AppEnv } from '../middleware/request-context';
import { characterBrowserCors, authenticatedBrowserCors } from '../config/cors';

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
const failureResponse = <Reason extends keyof typeof failures>(
  reason: Reason,
) => protectedError(failures[reason][1], failures[reason][2]);

const multipleFailures = (
  first: keyof typeof failures,
  second: keyof typeof failures,
) => ({
  description: [failures[first][2], failures[second][2]].join(' '),
  headers,
  content: {
    'application/json': {
      schema: z.object({
        error: z.object({
          code: z.enum([failures[first][1], failures[second][1]]),
          message: z.string(),
          requestId: z.uuid(),
        }),
      }),
    },
  },
});

const commonErrors = {
  400: failureResponse('invalid_request'),
  401: unauthenticatedResponse,
  403: failureResponse('player_link_required'),
  503: failureResponse('unavailable'),
  500: { ...internalErrorResponse, headers },
};
const query = z.strictObject({});
const params = z.strictObject({ characterId: z.uuid() });
const security = [{ SupabaseBearer: [] }];
const read = {
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
const write = {
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

const characterPath = '/api/v1/characters';
const detailPath = '/api/v1/characters/{characterId}';

const json = <S extends z.ZodType>(schema: S) => ({
  'application/json': { schema },
});
const success = <S extends z.ZodType>(schema: S, description: string) => ({
  description,
  headers,
  content: json(schema),
});
const body = <S extends z.ZodType>(schema: S) => ({
  content: json(schema),
  required: true,
});

const listRoute = createRoute({
  ...read,
  method: 'get',
  path: characterPath,
  operationId: 'listCharacters',
  summary: 'List the current player’s characters',
  responses: {
    ...commonErrors,
    200: success(characterList, 'Owned character summaries in creation order.'),
  },
});
const capacityRoute = createRoute({
  ...read,
  method: 'get',
  path: '/api/v1/characters/capacity',
  operationId: 'getCharacterCapacity',
  summary: 'Get the current player’s character slots',
  responses: {
    ...commonErrors,
    200: success(
      characterCapacity,
      'Total, used and available slots. Available is zero when over capacity.',
    ),
  },
});
const detailRoute = createRoute({
  ...read,
  method: 'get',
  path: detailPath,
  operationId: 'getCharacter',
  request: { query, params },
  summary: 'Get an owned character sheet',
  responses: {
    ...commonErrors,
    200: success(characterDetail, 'The owned character sheet.'),
    404: failureResponse('not_found'),
  },
});
const createRouteConfig = createRoute({
  ...write,
  method: 'post',
  path: characterPath,
  operationId: 'createCharacterDraft',
  request: { query, body: body(createDraft) },
  summary: 'Create a character draft',
  responses: {
    ...commonErrors,
    201: success(characterDetail, 'The new draft with its revision.'),
    409: failureResponse('capacity_reached'),
    413: failureResponse('too_large'),
    422: failureResponse('invalid_program'),
  },
});
const editRoute = createRoute({
  ...write,
  method: 'patch',
  path: detailPath,
  operationId: 'editCharacterDraft',
  request: { query, params, body: body(editDraft) },
  summary: 'Edit an owned draft or sheet awaiting corrections',
  description:
    'Supply the current revision and at least one editable field. Omit a field to preserve it, and use null to clear it.',
  responses: {
    ...commonErrors,
    200: success(characterDetail, 'The edited sheet with a new revision.'),
    404: failureResponse('not_found'),
    409: multipleFailures('character_locked', 'revision_conflict'),
    413: failureResponse('too_large'),
    422: failureResponse('invalid_program'),
  },
});
const submitRoute = createRoute({
  ...write,
  method: 'post',
  path: '/api/v1/characters/{characterId}/submit',
  operationId: 'submitCharacter',
  request: { query, params, body: body(submitDraft) },
  summary: 'Submit an owned character sheet for staff review',
  description:
    'Requires the current revision, first and last names, personality, physical description, face claim and backstory. Students also require an active program.',
  responses: {
    ...commonErrors,
    200: success(characterDetail, 'The submitted sheet with a new revision.'),
    404: failureResponse('not_found'),
    409: multipleFailures('character_locked', 'revision_conflict'),
    413: failureResponse('too_large'),
    422: multipleFailures('incomplete', 'invalid_program'),
  },
});

type CharacterArguments =
  Database['public']['Functions']['player_characters']['Args'];
type Catalog = 'houses' | 'programs' | 'clubs';
async function request<S extends z.ZodType>(
  c: Context<AppEnv>,
  schema: S,
  input: CharacterArguments | { catalog: Catalog },
): Promise<z.output<S>> {
  const auth = c.var.auth;
  if (!auth) throw new CharacterRequestError('unauthenticated');
  let result;
  try {
    const client = createSupabaseClient(c.env, {
      accessToken: auth.accessToken,
    });
    const query =
      'catalog' in input
        ? client.rpc('player_character_catalog', input)
        : client.rpc('player_characters', input);
    result = rpcResult.parse(
      await runSupabaseQuery(() =>
        query.abortSignal(AbortSignal.timeout(5000)),
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

function invalid(result: { success: boolean }): undefined {
  if (!result.success) throw new CharacterRequestError('invalid_request');
}

export function registerCharacterRoutes(app: OpenAPIHono<AppEnv>) {
  app.use(`${characterPath}/*`, noStore, characterBrowserCors);
  app.openapi(
    listRoute,
    async (c) =>
      c.json(await request(c, characterList, { operation: 'list' }), 200),
    invalid,
  );
  app.openapi(
    capacityRoute,
    async (c) =>
      c.json(
        await request(c, characterCapacity, { operation: 'capacity' }),
        200,
      ),
    invalid,
  );
  app.openapi(
    detailRoute,
    async (c) =>
      c.json(
        await request(c, characterDetail, {
          operation: 'detail',
          target_id: c.req.valid('param').characterId,
        }),
        200,
      ),
    invalid,
  );
  app.openapi(
    createRouteConfig,
    async (c) =>
      c.json(
        await request(c, characterDetail, {
          operation: 'create',
          fields: c.req.valid('json'),
        }),
        201,
      ),
    invalid,
  );
  app.openapi(
    editRoute,
    async (c) => {
      const { expectedRevision, ...fields } = c.req.valid('json');
      return c.json(
        await request(c, characterDetail, {
          operation: 'edit',
          target_id: c.req.valid('param').characterId,
          expected_revision: expectedRevision,
          fields,
        }),
        200,
      );
    },
    invalid,
  );
  app.openapi(
    submitRoute,
    async (c) =>
      c.json(
        await request(c, characterDetail, {
          operation: 'submit',
          target_id: c.req.valid('param').characterId,
          expected_revision: c.req.valid('json').expectedRevision,
        }),
        200,
      ),
    invalid,
  );

  const catalogs = [
    ['houses', 'listHouses', characterCatalog],
    ['programs', 'listPrograms', characterCatalog],
    ['clubs', 'listClubs', clubCatalog],
  ] as const;
  for (const [catalog, operationId, schema] of catalogs) {
    const route = createRoute({
      ...read,
      method: 'get',
      path: `/api/v1/catalogs/${catalog}`,
      operationId,
      summary: `List active ${catalog}`,
      responses: {
        ...commonErrors,
        200: success(schema, 'Active catalog entries sorted by slug.'),
      },
    });
    app.use(route.path, noStore, authenticatedBrowserCors);
    app.openapi(
      route,
      async (c) => c.json(await request(c, schema, { catalog }), 200),
      invalid,
    );
  }
}
