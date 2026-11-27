# Business rules

Harvard University RP uses the Digital Campus to manage characters and campus services. Roleplay scenes continue on Discord. Character sheets contain fictional character information. The schema starts with database-only administrative access.

| Area                           | Confirmed rule                                                                                                                 | Implementation                                                                                                                                                                  |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Player identity                | One player per Discord account. A player may own multiple characters.                                                          | A unique Discord snowflake identifies the player. Supabase Auth can be linked later. HRP staff actor records are independent of character type.                                 |
| Character capacity             | Five base slots plus one per active confirmed boost, without a business cap on bonus slots.                                    | Capacity comes from the latest absolute count. Staff may record manual confirmations. The model has no Discord boost counter integration.                                       |
| Loss of a boost                | Characters must be preserved. The staff is considering suspension for excess characters after voluntary removal.               | A decrease changes the calculated capacity and leaves character records and use states intact. A trusted writer can suspend and reactivate a character independently of review. |
| Review                         | Players submit their sheets on the site. Staff reviews them and assigns Houses. Approved students require a House.             | A reviewed state must match a staff review for the same character. House assignments must match a review for the same character. The owner cannot review their own character.   |
| Campus and community           | The campus is for validated characters. Citizens and other characters outside Harvard can access community features.           | Validation is represented in the database. Access policies and community features are deferred.                                                                                 |
| Clubs                          | A character can hold two active memberships. The BDE can have ten active members.                                              | PostgreSQL enforces both limits on inserts, updates and concurrent writes. The law club appears as inactive and swimming has one entry.                                         |
| Programs                       | The program list is extensible.                                                                                                | Houses, programs and clubs are editable catalogs with stable UUIDs and unique slugs.                                                                                            |
| Social profiles and reputation | An RP Instagram profile belongs to a character. Reputation can increase or decrease, and the ranking is reserved for students. | These are requirements for later modules.                                                                                                                                       |

## Proposed review states

The initial states are `draft`, `submitted`, `changes_requested`, `approved` and `rejected`. The proposed workflow is to submit a draft, receive a staff decision and resubmit after a correction request. PostgreSQL checks that a decision and any assigned House are supported by the review records. The sequence of permissible transitions is still open. The optional assignment history can span reviews, so a later approval can retain the House from an earlier review.

A character uses one of `active` and `suspended` independently of validation. Here `active` means the use state is unsuspended. Campus access will also require the validation and authorization checks defined in a later mission.

## HU-009A development policy

The [character lifecycle](CHARACTERS.md) uses the existing player, profile and sheet records. During development every existing character occupies one slot, including drafts, refused characters and suspended characters. Owners may edit and submit drafts and sheets awaiting corrections. Submitted, approved and refused sheets are locked. Boost loss preserves all data and use states. The field matrix and transition rules in HU-009A await staff approval before release.

## HU-009B development policy

[Staff review](CHARACTER_REVIEWS.md) applies the provisional submitted-only workflow. An authorized HRP actor can append an approval, correction request or rejection for another player's sheet. Corrections and rejections include a player-facing comment. An authorized student approval or correction request can assign an active House. A later decision may preserve an existing assignment and its review reference. Validation and use status remain independent. The transition and visibility policy awaits staff approval.

## Open decisions

- Which validation or use states consume a character slot, how excess characters are selected, timing and reactivation, and boost exceptions.
- Staff authorization, separation of duties, editing an approved sheet, resubmission and retention of past decisions.
- Field visibility and presentation, minimum-length rules for personality, physical description and backstory, and procedures for handling content warnings and face claims.
- Club eligibility for non-students, membership applications and leadership, swimming's leadership title, and confirmation of the law club.
- Reputation scoring and ranking rules, academic rules, and the Gossip, relationships and messaging models.
