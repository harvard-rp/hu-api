# Character review

This page describes the merged HU-009B implementation. The [approved HU-009F-A target and migration proposal](CHARACTER_POLICY.md) document future behavior.

HU-009B gives linked HRP actors with the effective `characters.review` capability a review queue and allows owners to read player-facing decisions. All routes require a Supabase Auth bearer token and return `Cache-Control: no-store`. Decisions and comments are stored in the existing `private.character_reviews` table. Comments are plain text intended for the player. This workflow has no confidential staff note field.

## HTTP contract

| Method and path                                       | Success | Request and result                                                                                                                                                        |
| ----------------------------------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GET /api/v1/staff/characters`                        | 200     | `{items, nextCursor}` of currently submitted sheets owned by other players. Each item has `id`, `revision`, `kind`, `useStatus`, `updatedAt`, `firstName` and `lastName`. |
| `GET /api/v1/staff/characters/{characterId}`          | 200     | The current submitted [character sheet](CHARACTERS.md) and its revision.                                                                                                  |
| `GET /api/v1/staff/characters/{characterId}/reviews`  | 200     | Chronological history for another player's submitted or previously reviewed character.                                                                                    |
| `POST /api/v1/staff/characters/{characterId}/reviews` | 201     | Records the decision and returns `{characterId, revision, houseId, review}`. The revision is the new sheet revision, and `houseId` is the effective assignment.           |
| `GET /api/v1/characters/{characterId}/reviews`        | 200     | Chronological history for an owned character, including earlier correction requests after resubmission.                                                                   |

Use `limit` from 1 to 50 on the queue, with a default of 20. The queue is ordered by character UUID, and `after` is the preceding page's `nextCursor`. Stop when `nextCursor` is null. Pagination reflects the live queue at each request. Fetch from the beginning to refresh it. The remaining operations accept no query parameters.

The decision body uses `application/json`, requires `expectedRevision` (from the submitted sheet) and `decision`, and accepts optional `comment` and `houseId`. The JSON body limit is 96 KiB. A supplied comment must be nonblank and no longer than 2,000 characters. Each history item and the decision response's `review` object contains only `decision`, `reviewedAt`, `comment` and `assignedHouseId`. `assignedHouseId` is null when that particular decision did not add a House, even if an earlier assignment remains effective. Histories use review timestamps then review UUIDs to order decisions. There are no reviewer or player account identifiers in these objects. The full schemas are available from `GET /openapi.json`.

| Status | Code                                | Condition                                                                                                                                           |
| ------ | ----------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| 400    | `INVALID_CHARACTER_REQUEST`         | Malformed UUID, query, JSON, content type, invalid type or length, or unknown field.                                                                |
| 401    | `UNAUTHENTICATED`                   | The token or session is missing or invalid.                                                                                                         |
| 403    | `PLAYER_LINK_REQUIRED`              | The authenticated account has no linked player.                                                                                                     |
| 403    | `CHARACTER_REVIEW_FORBIDDEN`        | Review capability is absent or was revoked while waiting.                                                                                           |
| 404    | `CHARACTER_NOT_FOUND`               | The requested character is absent or outside the operation's visibility. Self-review and direct access to another player's draft use this response. |
| 409    | `CHARACTER_NOT_SUBMITTED`           | A visible character already received a decision and is no longer submitted.                                                                         |
| 409    | `CHARACTER_REVISION_CONFLICT`       | The submitted sheet's revision changed. Reload and review the current version before trying again.                                                  |
| 413    | `CHARACTER_REQUEST_TOO_LARGE`       | The JSON body exceeds the HTTP limit.                                                                                                               |
| 422    | `CHARACTER_REVIEW_COMMENT_REQUIRED` | A correction request or rejection lacks a player-facing comment.                                                                                    |
| 422    | `CHARACTER_HOUSE_REQUIRED`          | Student approval has no existing or proposed House.                                                                                                 |
| 422    | `INVALID_CHARACTER_HOUSE`           | The UUID does not identify an active House for a new assignment, or the requested assignment is incompatible with the character kind or decision.   |
| 503    | `SERVICE_UNAVAILABLE`               | Auth or the Data API failed or could not provide a trustworthy response.                                                                            |
| 500    | `INTERNAL_ERROR`                    | Unexpected application failure.                                                                                                                     |

Errors use the standard `error` object with `code`, `message` and `requestId`. Logs hold the generated request ID, status and allowlisted Auth diagnostics. The HTTP layer suppresses database details, request bodies, narratives and comments.

## Provisional decision policy

| Decision            | Comment  | New House assignment                                                                               |
| ------------------- | -------- | -------------------------------------------------------------------------------------------------- |
| `approved`          | Optional | Allowed for students. An existing valid assignment or a new active House is required for students. |
| `changes_requested` | Required | Optional for students.                                                                             |
| `rejected`          | Required | Only an existing assignment can be retained.                                                       |

All three decisions start from `submitted`. If `houseId` is omitted, the character retains the existing House and original review reference. A historical assignment backed by the database's review reference remains valid if its House later becomes inactive. New assignments always reference active catalog entries and are restricted to student approvals and correction requests. There is no automatic assignment. Decisions preserve the use state, so an approved but suspended character remains ineligible for the campus.

A correction request returns the character to the HU-009A owner workflow. The next submission can receive a new decision and the earlier outcomes remain visible in the owner's history. Pending staff and player review of this policy, rejected and approved characters stay locked, review comments are visible to the owner and eligible reviewers, and staff detail access is limited to submitted sheets. Validate the provisional rules and historical comment visibility before rollout.

## Database boundary and transaction

The authenticated PostgREST facades are `public.staff_character_reviews()` and `public.player_character_review_history()`. Both run with invoker rights and delegate to bounded routines in the unexposed `character_review` schema. Their dedicated owner has no login or RLS bypass. RLS allows the role to resolve only the caller's linked player and effective review capability, read only other players' submitted profiles and sheets, append reviews within its review scope and update only decision and House references. Owner history checks ownership even if the owner also has reviewer capability.

A decision uses `READ COMMITTED`. PostgreSQL verifies the session and link, checks the capability, locks the submitted row and rechecks the session, player link and capability. It then checks the revision, appends the review and updates the existing character's status and references in the same transaction. The HU-009A trigger rotates the revision. The original foreign keys and no-self-review check remain in force. When two decisions compete, one succeeds and the other finds the character outside the submitted state. A failed character write rolls back the review insert as well. [PostgreSQL transaction isolation](https://www.postgresql.org/docs/17/transaction-iso.html)

The staff grant is checked from PostgreSQL on every request. When a decision adds a House, it also takes a shared row lock on the active catalog entry and rechecks authorization. This serializes the decision with a concurrent deactivation. Revocations committed during either lock wait are checked before deciding. Requests already past that check may complete. The API uses only the existing publishable-key and user JWT path, and SQL applies the same checks to direct PostgREST calls. Discord permissions, role synchronization, approval notifications and real staff grants are outside this workflow.
