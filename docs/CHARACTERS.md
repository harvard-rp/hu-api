# Player character lifecycle

HU-009A lets a linked player work on their own fictional character sheets. The Worker verifies a Supabase Auth bearer token with Auth and forwards it with the project's publishable key. PostgreSQL resolves the player from the Auth subject and rechecks the active session. The endpoints use `Cache-Control: no-store`. Use the server-generated `X-Request-Id` to correlate a response with its log entry.

## HTTP contract

| Method and path                                | Success | Request and result                                                                                                                  |
| ---------------------------------------------- | ------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `GET /api/v1/characters`                       | 200     | Array of summaries ordered by creation time, then ID. Includes ID, kind, validation and use states, revision, timestamps and names. |
| `GET /api/v1/characters/capacity`              | 200     | `{ "total": 5, "used": 0, "available": 5 }` for a new player.                                                                       |
| `GET /api/v1/characters/{characterId}`         | 200     | Full owned sheet with the current revision. Unset fields are null.                                                                  |
| `POST /api/v1/characters`                      | 201     | JSON with a required `kind` and optional editable fields. Returns the new draft and its revision.                                   |
| `PATCH /api/v1/characters/{characterId}`       | 200     | JSON with `expectedRevision` and at least one editable field. Returns the updated sheet with a new revision.                        |
| `POST /api/v1/characters/{characterId}/submit` | 200     | JSON with `expectedRevision` only. Returns the submitted sheet with a new revision.                                                 |
| `GET /api/v1/catalogs/houses`                  | 200     | Array of active entries with `id`, `slug` and `name`, sorted by slug.                                                               |
| `GET /api/v1/catalogs/programs`                | 200     | Array of active entries with `id`, `slug` and `name`, sorted by slug.                                                               |
| `GET /api/v1/catalogs/clubs`                   | 200     | Array of active entries with `id`, `slug`, `name` and `memberCapacity`, sorted by slug. Capacity is null for an uncapped club.      |

Retrieve the schemas and per-operation response codes at `GET /openapi.json`. Write requests use `Content-Type: application/json` and are limited to 96 KiB. Omitted fields are preserved during an edit. Send null to clear a field. Path IDs and revisions are UUIDs. The revision is opaque. After a conflict, reload the sheet before retrying. All endpoints require a linked account and accept no query parameters. The catalog responses are read-only.

| Status | Error code                    | Condition                                                                                                                                 |
| ------ | ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| 400    | `INVALID_CHARACTER_REQUEST`   | Invalid path ID, query, content type, JSON, field or field applicability. Includes unknown fields, an empty patch and a missing revision. |
| 401    | `UNAUTHENTICATED`             | The token or session is missing, invalid or ineligible. The response includes `WWW-Authenticate: Bearer`.                                 |
| 403    | `PLAYER_LINK_REQUIRED`        | Eligible Auth account without a linked player.                                                                                            |
| 404    | `CHARACTER_NOT_FOUND`         | The character does not exist or belongs to another player.                                                                                |
| 409    | `CHARACTER_CAPACITY_REACHED`  | No slot is available when creating a draft.                                                                                               |
| 409    | `CHARACTER_LOCKED`            | The current validation state disallows editing or submitting.                                                                             |
| 409    | `CHARACTER_REVISION_CONFLICT` | The request carries an obsolete revision for an editable character.                                                                       |
| 413    | `CHARACTER_REQUEST_TOO_LARGE` | The HTTP JSON body exceeds 96 KiB.                                                                                                        |
| 422    | `INVALID_CHARACTER_PROGRAM`   | A program supplied in an edit or checked at submission is inactive, unknown or incompatible with the kind.                                |
| 422    | `CHARACTER_INCOMPLETE`        | A required submission field is empty or missing.                                                                                          |
| 503    | `SERVICE_UNAVAILABLE`         | Auth or the Data API is unavailable or returned an unusable response.                                                                     |
| 500    | `INTERNAL_ERROR`              | Unexpected application failure.                                                                                                           |

Errors use `{ "error": { "code": "...", "message": "...", "requestId": "..." } }`. Character responses omit the player ID, Auth and Discord identifiers, capabilities and review notes. Narrative fields appear only in owned detail and write responses.

## Provisional field matrix

A draft requires a kind and can otherwise be empty. These submission and applicability rules are development defaults awaiting staff approval.

| Field group                                                                                                                                     | Student                                     | Teacher      | Staff member | Citizen      |
| ----------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------- | ------------ | ------------ | ------------ |
| First and last names, personality, physical description, face claim and backstory                                                               | Required                                    | Required     | Required     | Required     |
| Active program                                                                                                                                  | Required                                    | Optional     | Inapplicable | Inapplicable |
| Scholarship status                                                                                                                              | Optional                                    | Inapplicable | Inapplicable | Inapplicable |
| Nickname, age, birth date and place, orientation, origins, residence, financial situation, occupation, anecdotes, content warnings and RP links | Optional                                    | Optional     | Optional     | Optional     |
| House                                                                                                                                           | Assigned by staff and required for approval | Read-only    | Read-only    | Read-only    |

Choose `student`, `teacher`, `staff_member` or `citizen` at creation. Kind is fixed for this workflow. Age is a nonnegative integer up to 32,767, matching PostgreSQL's existing field type. Birth dates use valid calendar dates in `YYYY-MM-DD` form. Names and nickname allow up to 80 characters each. Other short text fields allow 120–300 characters as specified in OpenAPI. Personality, physical description and anecdotes allow up to 4,000 characters each, and backstory allows up to 12,000. Warnings and RP links each allow up to 12 nonblank strings with limits of 120 and 300 characters respectively. RP links are textual RP references. The API never fetches them. Face claim is a text reference without media upload. Enter only fictional character information and omit any real-world personal details.

Owners use [the review history route](CHARACTER_REVIEWS.md) to read their decisions and correction requests.

## Policy and concurrency

Five base slots plus one per latest confirmed active boost determine capacity. Every existing character consumes a slot during this phase. If a boost decrease leaves a player over capacity, `available` is zero and all characters, validation states and use states are preserved. The provisional change policy allows only `draft` and `changes_requested` to be edited or submitted. The use state is independent of the validation state. Resubmission retains historical reviews and any existing staff-assigned House. It clears the prior current-review pointer and changes validation to `submitted`. Campus eligibility remains subject to the existing approved-and-active rule.

Creation takes the player-scoped capacity transaction lock before counting at `READ COMMITTED`. The same advisory key protects boost-confirmation inserts. A future confirmation writer must call `private.lock_character_capacity(player_id)` **before** reading the current count or allocating its confirmation revision. The insert trigger also acquires the lock for trusted direct inserts. The lock covers the transactional API boundary. Trusted maintenance writes outside that boundary must take the same lock before creating a character or changing an allowance. Boost history is append-only.

Patch and submit lock the character row and verify the revision after the lock. Profile, sheet and character writes commit together. The revision rotates on character-row updates, including trusted changes to review or use status. The HU-009B decision writer locks that row and checks the reviewed revision before updating it. A trusted profile or sheet write must update the character row in the same transaction so stale clients can detect the change.

The public RPC facades use invoker rights. Their constrained implementation sits in the unexposed `character_lifecycle` schema. A dedicated non-login owner with no RLS bypass can see only the caller's rows and active catalog entries. It holds no permissions to assign a House, modify eligibility or grant HRP rights. A signed token cannot use the new RPCs after session deletion. Actor or role data supplied by the player conveys no authority.

## Decisions before release

Staff approval remains open for slot-consuming states, the submission matrix and editorial minima, type changes, the treatment of refused or excess characters, archival or deletion, and staff review and data visibility. Staff review is documented in [HU-009B](CHARACTER_REVIEWS.md). Club admission remains outside this workflow. Validate the provisional policy before applying this migration or deploying these HTTP routes remotely.
