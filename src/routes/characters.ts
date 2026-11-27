import { createRoute, type z, type OpenAPIHono } from '@hono/zod-openapi';
import type { Context } from 'hono';

import { authenticatedBrowserCors } from '../config/cors';
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
  characterCapacity,
  characterCatalog,
  characterDetail,
  characterList,
  clubCatalog,
  createDraft,
  editDraft,
  submitDraft,
} from '../lib/character-sheet';
import type { Database } from '../lib/supabase/database.types';
import { noStore } from '../middleware/authentication';
import type { AppEnv } from '../middleware/request-context';

const characterPath = '/api/v1/characters';
const detailPath = '/api/v1/characters/{characterId}';

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
const archivesRoute = createRoute({
  ...read,
  method: 'get',
  path: '/api/v1/characters/archives',
  operationId: 'listCharacterArchives',
  summary: 'List the current player’s archived characters',
  responses: {
    ...commonErrors,
    200: success(characterList, 'Owned archive summaries in creation order.'),
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
  summary: 'Edit an owned draft, sheet in correction or unarchived refusal',
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
    'Requires the current revision, mode, first and last names, age, birth date and face claim. Students need an active program. Teachers and staff members need an occupation. Inline sheets must meet editorial line limits. External sheets need an allowed viewing link.',
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
function request<S extends z.ZodType>(
  c: Context<AppEnv>,
  schema: S,
  input: CharacterArguments | { catalog: Catalog },
) {
  return requestCharacterData(c, schema, (client) =>
    'catalog' in input
      ? client.rpc('player_character_catalog', input)
      : client.rpc('player_characters', input),
  );
}

export function registerCharacterRoutes(app: OpenAPIHono<AppEnv>) {
  app.openapi(
    listRoute,
    async (c) =>
      c.json(await request(c, characterList, { operation: 'list' }), 200),
    invalid,
  );
  app.openapi(
    archivesRoute,
    async (c) =>
      c.json(await request(c, characterList, { operation: 'archives' }), 200),
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
