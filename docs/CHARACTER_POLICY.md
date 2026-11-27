# HU-009F character policy

The API stores hybrid sheets, maintains lifetime refusal counts and releases capacity only when a character is archived. The [owner](CHARACTERS.md), [reviewer](CHARACTER_REVIEWS.md) and [reopening](CHARACTER_REOPENING.md) contracts describe each route. The [migration guide](CHARACTER_POLICY_MIGRATION.md) covers inherited data and the coordinated HU-009F-C release.

## Sheet modes and submission fields

Choose inline authoring or an external Canva, Google Docs or Google Sites sheet. Drafts may be incomplete. Character ID, owner, type, fictional identity, program and scholarship where applicable, and any future campus reservations are structured. Existing clubs and club reservations remain independent of this workflow.

| At submission                                                          | Student                   | Teacher              | Staff member         | Citizen              |
| ---------------------------------------------------------------------- | ------------------------- | -------------------- | -------------------- | -------------------- |
| Type, sheet mode, first and last names, age, birth date and face claim | Required                  | Required             | Required             | Required             |
| Active program                                                         | Required                  | Optional             | Inapplicable         | Inapplicable         |
| Occupation                                                             | Optional                  | Required             | Required             | Optional             |
| Scholarship                                                            | Optional                  | Inapplicable         | Inapplicable         | Inapplicable         |
| Inline physical description, personality and backstory                 | Required in inline        | Required in inline   | Required in inline   | Required in inline   |
| External viewing URL                                                   | Required in external      | Required in external | Required in external | Required in external |
| Other fictional descriptive fields, warnings, anecdotes and RP links   | Optional                  | Optional             | Optional             | Optional             |
| House                                                                  | Staff assigns at approval | Inapplicable         | Inapplicable         | Inapplicable         |

House, ownership, reputation, suspension and HRP capabilities are protected from owner writes. Use fictional data only. Reviewers judge quality, substance, internal coherence and the fit with a House. The API checks explicit nonblank lines in inline mode. It normalizes CRLF and CR to LF, trims surrounding whitespace for counting and ignores empty lines and visual wraps. Physical description needs at least five lines, personality five through ten and backstory ten through fifteen. Existing technical size limits still apply. Reviewers check the same editorial requirements manually for external documents.

### External documents

The server accepts lowercase HTTPS URLs of at most 2,048 characters with these exact hosts and paths. Path segments use ASCII letters, numbers, underscores and hyphens. Optional query and fragment content may include ordinary URL characters and well-formed percent escapes. Noncanonical hosts, explicit ports, credentials, encoded paths, shortened links and malformed inputs are rejected.

| Host               | Accepted paths                                                                                                                                                     |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `www.canva.com`    | `/design/{design}/view` or `/design/{design}/{share}/view`                                                                                                         |
| `docs.google.com`  | `/document/d/{id}/{edit,view,preview}`, the equivalent with `/u/{n}` before `/d`, or `/document/d/e/{publishedId}/pub` with the same optional account path segment |
| `sites.google.com` | `/view/{site}` with optional published page path and trailing slash                                                                                                |

A Google Docs share link may use `/edit` even for a viewer. Provider permissions still govern access. Reviewers open links manually. They must never request a password or edit access. When an inaccessible link requires correction, record that the reviewer manually attempted to view the submitted link and explain the access issue in their comment. An approval attests that the reviewer manually examined the content. The record retains the submitted URL, examined revision, authenticated reviewer, review time and attestation. The document can later change or disappear. A normal sheet edit or a replacement URL proceeds through revision and submission checks. Changes behind an unchanged URL require a report or manual recheck. No server-side retrieval, embedding, scraping or download occurs. See [Google Docs version history](https://support.google.com/docs/answer/190843?hl=en) for provider access limits.

## Transitions

Archive disposition and use state are separate from validation status. All decisions preserve prior history. Actions outside this table are denied.

| From                                    | Actor and action                                    | To                            | Refusal and capacity effects                            |
| --------------------------------------- | --------------------------------------------------- | ----------------------------- | ------------------------------------------------------- |
| No character                            | Owner creates with a slot                           | Draft                         | Count 0, uses a slot                                    |
| Draft, correction or unarchived refusal | Owner edits current revision                        | Same state                    | Unchanged                                               |
| Draft, correction or unarchived refusal | Owner submits valid current revision                | Submitted                     | Unchanged                                               |
| Submitted                               | Reviewer approves                                   | Approved                      | Unchanged. New active House allowed only for students   |
| Submitted                               | Reviewer requests correction with comment           | Correction                    | Unchanged. New House prohibited                         |
| Submitted with zero or one refusal      | Reviewer refuses with comment                       | Editable refusal              | Adds one and keeps slot                                 |
| Submitted with at least two refusals    | Reviewer refuses with comment                       | Archived refusal              | Adds one and releases slot                              |
| Archived                                | Owner sends reason against current archive revision | Archived with pending request | Unchanged, even at capacity                             |
| Archived with pending request           | Staff declines with justification                   | Archived                      | Unchanged. Another request may be filed with a fresh ID |
| Archived with pending request           | Staff accepts with justification and free slot      | Draft                         | Retains lifetime count and acquires slot                |
| Any character                           | Trusted independent change to use status            | Same lifecycle state          | Slot unchanged                                          |

A reopened sheet retains its count of three or more and permits another review attempt, including any number of corrections. A refusal begins a new archive cycle. There is no self-review or self-reopening, automatic cooldown, direct owner reopening or permanent automatic deletion. Current lists exclude archives. Campus eligibility requires an approved, active and current character.

## Capacity and transactions

Capacity equals five plus the latest count of active confirmed boosts. All current characters use one slot, including drafts, suspended characters, editable refusals and reopened characters. Archive requests use no slot. A decrease in capacity preserves characters and clamps availability to zero.

Lock player capacity before a character row for any slot-changing write. A catalog row lock comes after the character lock when both apply. A refusal commits the decision, lifetime count, archive disposition and character revision together. Reopening commits the decision and draft revision together. The existing boost confirmation lock shares the same key. Trusted capacity writers acquire it before obtaining the next confirmation revision. Trusted catalog writers must not take a capacity or character lock while holding a catalog row lock.

Writes use fresh PostgreSQL reads after relevant waits under READ COMMITTED. Review submissions and decisions use the expected revision. Each examined revision can have only one review. Reopening scopes requests to the current archival review, enforces one pending request per cycle and rejects stale request IDs or revisions. After an uncertain response, load the current state and histories before choosing a fresh action. PostgREST enforces the same rules as the Worker. Raw tables and privileged function schemas remain off the Data API. Logs omit document URLs, character content and comments.

## Notifications and remaining decisions

For HU-010A, plan events `character.approved`, `character.changes_requested`, `character.rejected`, `character.archived`, `character.reopening_requested` and `character.reopening_decided`. A threshold refusal produces related refusal and archive events. A later transactional outbox should store stable event IDs, character ID, revision and event timestamp, without comments, external URLs or bearer credentials. Delivery, retry, recipients, channels and consent remain HU-010A decisions. Database transactions have no Discord service dependency.

Staff still need a policy for material changes to external content after approval, evidence retention, intentionally recreated characters, archival retention and future amendments to approved sheets. This implementation cannot prove the identity or immutability of an external document or infer that two fictional character records are replacements. Discord role reconciliation and real capability grants remain separately authorized activities.
