# Player and HRP permissions

| Caller                                                 | Access in HU-005                                                                                                                    |
| ------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| Anonymous visitor                                      | Public health and OpenAPI routes. The player context RPC cannot be executed.                                                        |
| Permanent Auth account without a player link           | The protected route returns `403 PLAYER_LINK_REQUIRED`. A direct RPC call returns null.                                             |
| Linked player                                          | Their own internal player ID, effective capabilities and minimal states of their own characters.                                    |
| Linked player with an approved, active character       | The context reports that character as campus-eligible. Individual university or community features require their own authorization. |
| Linked player with a suspended or unapproved character | The account context remains accessible. The character is ineligible for campus access.                                              |
| HRP actor                                              | Only the capability rows explicitly granted for their linked player. The context still contains solely their own characters.        |

`characters.review` and `boosts.manage` are initial capability codes. `characters.review` controls access to the review workflow. `boosts.manage` is reserved for a later workflow. Clients can [initialize the current player](DISCORD_AUTH.md) and run the bounded [player character lifecycle](CHARACTERS.md). Permission grants remain restricted to trusted operators. Authorized HRP actors can append decisions through the bounded review workflow. An RP type such as `teacher` or `staff_member` conveys no HRP authority. The existing character review constraint prevents self-review.

## PostgreSQL boundary

The migration `20261126235738_player_context_authorization.sql` adds the closed-by-default `private.staff_capabilities` table. Its primary key allows one row per actor and capability. The foreign key requires a registered HRP actor. Database operators may insert or delete grant rows. The next read resolves the grants from the database, including when the caller reuses an unchanged token.

Only `authenticated` can execute `public.current_player_context()`. It runs with invoker rights, an empty search path and a SQL-standard body whose private object references resolve when created. The role receives column-scoped SELECT grants for three tables and no access to look up objects in the `private` schema. That schema remains outside the Data API. These grants cover only the IDs needed for linkage and ownership, character validation/use states and capability codes. There are no client grants for private sheets, reviews, boost records or the staff registry.

The player policy matches the verified `auth.uid()` to the player's `auth_user_id`. A restrictive policy additionally requires the issuer's boolean `is_anonymous` claim to be false. Character and capability policies restrict rows to the caller's own visible player. The RPC projects only approved response fields and returns null for a missing link. The same rules hold for PostgREST callers that skip Hono. No policy derives authority from `user_metadata` or from client-supplied role, player or character selectors.

## Player initialization

The invoker facade `public.bootstrap_discord_player()` delegates the write to `account_bootstrap.initialize_current_player()`, which has no parameters. The non-login owner `hu_player_bootstrap` cannot bypass RLS. Auth SELECT grants and policies are scoped to the caller's user, sessions and Discord identity. An invoker helper binds Auth relations at migration time, with no Auth schema usage grant to the dedicated role. The owner can insert the caller's player and read only the linkage columns of that caller's row. It receives no update or delete permission. The facade reads the success context under the original caller's HU-005 policies. `private` and `account_bootstrap` stay unexposed.

## Character lifecycle

`public.player_characters()` and `public.player_character_catalog()` are authenticated invoker facades for the bounded functions in the unexposed `character_lifecycle` schema. The dedicated `hu_character_lifecycle` owner has no login or RLS bypass. Session reads are scoped to the Auth subject. Per-table RLS binds character, profile, sheet and capacity access to that subject's player link. Catalog RLS exposes active rows to the function owner.

Direct callers and Worker requests share the same ownership, session, field and transition checks. Client roles have no table grants for profile or sheet access. An RP character kind conveys no HRP capabilities. The character writer cannot change ownership, use status, House, review history or permission grants.

## Character review

The [review routes](CHARACTER_REVIEWS.md) require an active session and a linked player. PostgreSQL resolves the `characters.review` grant from `private.staff_capabilities` on every staff call and rechecks it after locking a submitted character for a decision. Staff queue and sheet access exclude the caller's own characters. The owner route projects only the player's own history. No client receives generic SELECT, UPDATE or DELETE access to reviews.

The `hu_character_review` role cannot log in or bypass RLS. The unexposed `character_review` schema implements the bounded RPC operations with scoped privileges. The role has no privilege to grant capabilities or alter use status. Decisions and House references are updated together, and no reviewer identifiers are projected.

## Archive and reopening boundary

The authenticated invoker facade `public.character_reopening()` delegates to the unexposed review implementation. Owner operations require a live session and linked character. Archives and resolutions for staff require the distinct `characters.reopen` grant. Self-resolution is denied in the RPC, RLS and database constraints. The non-login review role reads character and boost projections to count occupied slots. Bounded endpoints expose archived sheets and request history without exposing current drafts belonging to another player. The migration creates no grant rows.

## Future reviewer role mapping

The direction designated these Discord role IDs as candidates for the same HRP capability. This is planning data.

| Discord role ID     | Future capability |
| ------------------- | ----------------- |
| 1470422368978604163 | characters.review |
| 1572702096581468250 | characters.review |
| 1470074424865591387 | characters.review |
| 1572701721967206470 | characters.review |

Propose resolving membership in the intended guild through a trusted server-side source against the verified Discord identity. Deny automatic grants if identity or guild membership cannot be verified. Track grant provenance so removing one mapped role does not remove another valid source or an authorized manual grant. Define verification freshness, role-loss handling, operator audit and a dry-run reconciliation before enabling synchronization. The API continues to check effective database capabilities. RP character types and player claims convey no HRP authority. The `characters.reopen` capability has no automatic mapping or implicit inheritance from `characters.review`.

## Open decisions

- Who can grant or revoke capabilities, verified guild membership and freshness, overlap with manual grants and the synchronization rollout.
- Audit retention and the operator, target, timestamp and reason to record for future grant and revoke workflows. `granted_at` records current grant creation. It is not an audit history.
- Review access to other characters' sheets, workflow transitions, permitted edits, and the domain permissions required by each campus feature.
