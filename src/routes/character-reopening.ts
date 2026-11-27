import { createRoute, z, type OpenAPIHono } from '@hono/zod-openapi';
import type { Context } from 'hono';

import {
  body,
  commonErrors,
  failureResponse,
  invalid,
  multipleFailures,
  params,
  query,
  read,
  requestCharacterData,
  success,
  write,
} from '../lib/character-http';
import {
  characterDetail,
  characterKind,
  rpString,
  submitDraft,
} from '../lib/character-sheet';
import type { Database } from '../lib/supabase/database.types';
import type { AppEnv } from '../middleware/request-context';
import { pagination, review } from './character-reviews';

const dateTime = z.iso.datetime({ offset: true });
const decision = z.enum(['accepted', 'declined']);
const requestReference = submitDraft.extend({ requestId: z.uuid() });
const ownerInput = requestReference.extend({ reason: rpString(2000) });
const staffInput = requestReference.extend({
  decision,
  justification: rpString(2000),
});
const reopening = z.strictObject({
  requestId: z.uuid(),
  requestedRevision: z.uuid(),
  reason: z.string(),
  requestedAt: dateTime,
  decision: decision.nullable(),
  justification: z.string().nullable(),
  decidedAt: dateTime.nullable(),
  resultingRevision: z.uuid().nullable(),
});
const timeline = z.array(reopening);
const archiveDetail = z.strictObject({
  sheet: characterDetail,
  reviews: z.array(review),
});
const archives = z.strictObject({
  items: z
    .array(
      z.strictObject({
        id: z.uuid(),
        kind: characterKind,
        revision: z.uuid(),
        archivedAt: dateTime,
        refusalCount: z.number().int().min(3),
        firstName: z.string().nullable(),
        lastName: z.string().nullable(),
        pendingRequestId: z.uuid().nullable(),
      }),
    )
    .max(50),
  nextCursor: z.uuid().nullable(),
});

const ownerPath = '/api/v1/characters/{characterId}/reopening-requests';
const staffPath = '/api/v1/staff/characters/{characterId}/reopening-requests';
const staffArchivePath = '/api/v1/staff/characters/archives';
const missing = { 404: failureResponse('not_found') };
const staffErrors = {
  ...commonErrors,
  403: multipleFailures('player_link_required', 'reopening_forbidden'),
};
const ownerHistory = createRoute({
  ...read,
  method: 'get',
  path: ownerPath,
  operationId: 'listOwnReopeningRequests',
  request: { query, params },
  responses: {
    ...commonErrors,
    ...missing,
    200: success(
      timeline,
      'Reopening requests and decisions for the owned character.',
    ),
  },
});
const ownerRequest = createRoute({
  ...write,
  method: 'post',
  path: ownerPath,
  operationId: 'requestCharacterReopening',
  description:
    'Send a client-generated requestId and the archive revision. Only one request can be pending per archive cycle. This operation reserves no slot.',
  request: { query, params, body: body(ownerInput) },
  responses: {
    ...commonErrors,
    ...missing,
    201: success(reopening, 'The pending reopening request.'),
    409: multipleFailures('reopening_conflict', 'revision_conflict'),
    413: failureResponse('too_large'),
  },
});
const staffList = createRoute({
  ...read,
  method: 'get',
  path: staffArchivePath,
  operationId: 'listStaffCharacterArchives',
  request: { query: pagination },
  responses: {
    ...staffErrors,
    200: success(
      archives,
      'Archive summaries and pending request IDs ordered by character ID.',
    ),
  },
});
const staffDetail = createRoute({
  ...read,
  method: 'get',
  path: '/api/v1/staff/characters/{characterId}/archive',
  operationId: 'getStaffCharacterArchive',
  request: { query, params },
  responses: {
    ...staffErrors,
    ...missing,
    200: success(archiveDetail, 'Archived sheet and review decisions.'),
  },
});
const staffHistory = createRoute({
  ...read,
  method: 'get',
  path: staffPath,
  operationId: 'listStaffReopeningRequests',
  request: { query, params },
  responses: {
    ...staffErrors,
    ...missing,
    200: success(timeline, 'Reopening requests and decisions.'),
  },
});
const staffResolve = createRoute({
  ...write,
  method: 'post',
  path: staffPath,
  operationId: 'decideCharacterReopening',
  description:
    'Resolve the identified pending request against the current archive revision. Acceptance requires a free slot and cannot be performed by the character owner.',
  request: { query, params, body: body(staffInput) },
  responses: {
    ...staffErrors,
    ...missing,
    200: success(
      reopening,
      'The decision and resulting draft revision on acceptance.',
    ),
    409: multipleFailures(
      'reopening_conflict',
      'revision_conflict',
      'capacity_reached',
    ),
    413: failureResponse('too_large'),
  },
});

function request<S extends z.ZodType>(
  c: Context<AppEnv>,
  schema: S,
  args: Database['public']['Functions']['character_reopening']['Args'],
) {
  return requestCharacterData(c, schema, (client) =>
    client.rpc('character_reopening', args),
  );
}

export function registerCharacterReopeningRoutes(app: OpenAPIHono<AppEnv>) {
  app.openapi(
    ownerHistory,
    async (c) =>
      c.json(
        await request(c, timeline, {
          operation: 'owner_history',
          target_id: c.req.valid('param').characterId,
        }),
        200,
      ),
    invalid,
  );
  app.openapi(
    ownerRequest,
    async (c) =>
      c.json(
        await request(c, reopening, {
          operation: 'request',
          target_id: c.req.valid('param').characterId,
          args: c.req.valid('json'),
        }),
        201,
      ),
    invalid,
  );
  app.openapi(
    staffList,
    async (c) => {
      const { limit, after } = c.req.valid('query');
      return c.json(
        await request(c, archives, {
          operation: 'staff_archives',
          page_size: limit === undefined ? undefined : Number(limit),
          after_id: after,
        }),
        200,
      );
    },
    invalid,
  );
  app.openapi(
    staffDetail,
    async (c) =>
      c.json(
        await request(c, archiveDetail, {
          operation: 'staff_detail',
          target_id: c.req.valid('param').characterId,
        }),
        200,
      ),
    invalid,
  );
  app.openapi(
    staffHistory,
    async (c) =>
      c.json(
        await request(c, timeline, {
          operation: 'staff_history',
          target_id: c.req.valid('param').characterId,
        }),
        200,
      ),
    invalid,
  );
  app.openapi(
    staffResolve,
    async (c) =>
      c.json(
        await request(c, reopening, {
          operation: 'resolve',
          target_id: c.req.valid('param').characterId,
          args: c.req.valid('json'),
        }),
        200,
      ),
    invalid,
  );
}
