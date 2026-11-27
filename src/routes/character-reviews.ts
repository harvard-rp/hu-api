import { createRoute, z, type OpenAPIHono } from '@hono/zod-openapi';

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
import type { AppEnv } from '../middleware/request-context';

const reviewDecision = z.enum(['approved', 'changes_requested', 'rejected']);
const dateTime = z.iso.datetime({ offset: true });
const decisionInput = submitDraft.extend({
  decision: reviewDecision,
  comment: rpString(2000).optional(),
  houseId: z.uuid().optional(),
  externalAttested: z.boolean().optional(),
});
export const review = z.strictObject({
  decision: reviewDecision,
  reviewedAt: dateTime,
  comment: z.string().nullable(),
  assignedHouseId: z.uuid().nullable(),
  examinedRevision: z.uuid().nullable(),
  archivedCharacter: z.boolean(),
  externalEvidence: z
    .strictObject({
      url: z.string(),
      attested: z.boolean(),
    })
    .nullable(),
});
const history = z.array(review);
const decisionResult = z.strictObject({
  characterId: z.uuid(),
  revision: z.uuid(),
  houseId: z.uuid().nullable(),
  refusalCount: z.number().int().nonnegative(),
  archivedAt: dateTime.nullable(),
  review,
});

export const pagination = z.strictObject({
  limit: z
    .string()
    .regex(/^(?:[1-9]|[1-4][0-9]|50)$/)
    .optional()
    .openapi({
      description: 'Page size from 1 to 50. Defaults to 20.',
      example: '20',
    }),
  after: z.uuid().optional().openapi({
    description: 'Use nextCursor from the preceding page.',
  }),
});
const queue = z.strictObject({
  items: z
    .array(
      z.strictObject({
        id: z.uuid(),
        kind: characterKind,
        revision: z.uuid(),
        useStatus: z.enum(['active', 'suspended']),
        updatedAt: dateTime,
        firstName: z.string().nullable(),
        lastName: z.string().nullable(),
      }),
    )
    .max(50),
  nextCursor: z.uuid().nullable(),
});

const staffPath = '/api/v1/staff/characters';
const detailPath = '/api/v1/staff/characters/{characterId}';
const reviewsPath = '/api/v1/staff/characters/{characterId}/reviews';
const staffErrors = {
  ...commonErrors,
  403: multipleFailures('player_link_required', 'forbidden'),
};
const missing = { 404: failureResponse('not_found') };
const queueRoute = createRoute({
  ...read,
  method: 'get',
  path: staffPath,
  operationId: 'listStaffReviewQueue',
  summary: 'List submitted sheets available for staff review',
  request: { query: pagination },
  responses: {
    ...staffErrors,
    200: success(
      queue,
      'Submitted sheets ordered by character ID. A null nextCursor indicates the last page.',
    ),
  },
});
const detailRoute = createRoute({
  ...read,
  method: 'get',
  path: detailPath,
  operationId: 'getStaffReviewSheet',
  summary: 'Read a currently submitted sheet as a reviewer',
  request: { query, params },
  responses: {
    ...staffErrors,
    ...missing,
    200: success(
      characterDetail,
      'The submitted sheet and its current revision.',
    ),
  },
});
const staffHistoryRoute = createRoute({
  ...read,
  method: 'get',
  path: reviewsPath,
  operationId: 'listStaffCharacterReviews',
  summary: 'Read decisions on a character available to the reviewer',
  request: { query, params },
  responses: {
    ...staffErrors,
    ...missing,
    200: success(history, 'Decisions in chronological order.'),
  },
});
const decisionRoute = createRoute({
  ...write,
  method: 'post',
  path: reviewsPath,
  operationId: 'decideStaffCharacterReview',
  summary: 'Record a staff decision on a submitted sheet',
  description:
    'The expected revision is required. Give the player a comment when requesting corrections or rejecting a sheet. Supply houseId to assign an active House to a student on approval. Omit houseId to retain a legacy assignment. External approvals and refusals require manual consultation attested with externalAttested: true. For a correction the attestation is optional. Inline reviews have no attestation.',
  request: { query, params, body: body(decisionInput) },
  responses: {
    ...staffErrors,
    ...missing,
    201: success(
      decisionResult,
      'The recorded decision, effective House and new character revision.',
    ),
    409: multipleFailures('not_submitted', 'revision_conflict'),
    413: failureResponse('too_large'),
    422: multipleFailures(
      'comment_required',
      'house_required',
      'invalid_house',
      'invalid_attestation',
    ),
  },
});
const ownerHistoryRoute = createRoute({
  ...read,
  method: 'get',
  path: '/api/v1/characters/{characterId}/reviews',
  operationId: 'listOwnCharacterReviews',
  summary: 'Read decisions on an owned character',
  request: { query, params },
  responses: {
    ...commonErrors,
    ...missing,
    200: success(history, 'Player-visible decisions in chronological order.'),
  },
});

export function registerCharacterReviewRoutes(app: OpenAPIHono<AppEnv>) {
  app.openapi(
    queueRoute,
    async (c) => {
      const { limit, after } = c.req.valid('query');
      const data = await requestCharacterData(c, queue, (client) =>
        client.rpc('staff_character_reviews', {
          operation: 'queue',
          page_size: limit === undefined ? undefined : Number(limit),
          after_id: after,
        }),
      );
      return c.json(data, 200);
    },
    invalid,
  );
  app.openapi(
    detailRoute,
    async (c) => {
      const data = await requestCharacterData(c, characterDetail, (client) =>
        client.rpc('staff_character_reviews', {
          operation: 'detail',
          target_id: c.req.valid('param').characterId,
        }),
      );
      return c.json(data, 200);
    },
    invalid,
  );
  app.openapi(
    staffHistoryRoute,
    async (c) => {
      const data = await requestCharacterData(c, history, (client) =>
        client.rpc('staff_character_reviews', {
          operation: 'history',
          target_id: c.req.valid('param').characterId,
        }),
      );
      return c.json(data, 200);
    },
    invalid,
  );
  app.openapi(
    decisionRoute,
    async (c) => {
      const data = await requestCharacterData(c, decisionResult, (client) =>
        client.rpc('staff_character_reviews', {
          operation: 'decide',
          target_id: c.req.valid('param').characterId,
          decision_input: c.req.valid('json'),
        }),
      );
      return c.json(data, 201);
    },
    invalid,
  );
  app.openapi(
    ownerHistoryRoute,
    async (c) => {
      const data = await requestCharacterData(c, history, (client) =>
        client.rpc('player_character_review_history', {
          target_id: c.req.valid('param').characterId,
        }),
      );
      return c.json(data, 200);
    },
    invalid,
  );
}
