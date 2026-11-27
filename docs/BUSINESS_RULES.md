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

## HU-009F character policy

[Character policy](CHARACTER_POLICY.md) defines the hybrid sheet model, submission matrix, editorial limits, state transitions, capacity and reopening. Players choose inline authoring or a manually reviewed Canva, Google Docs or Google Sites link. Both modes retain structured fictional identity and campus reservation data.

Correction and refusal require a player-facing comment. Only refusals increment the count. The first two allow revision and resubmission. The third archives the sheet and releases its slot. Archived sheets require explicit authorization and a free slot to reopen. All other states occupy capacity, including suspended characters unless archived. Total capacity remains five plus one per confirmed active boost. Preserve the full history and all existing character data.

Staff assigns a House only on final student approval. The owner cannot assign Houses or change reputation. The existing development behavior is documented in [player characters](CHARACTERS.md) and [character reviews](CHARACTER_REVIEWS.md). These contracts and the database require a later implementation before the target rules take effect.

## Open decisions

- Excess-character selection and timing, reactivation and any boost exceptions remain open. Slot-consuming states are defined in the approved target.
- Staff reopening authority, separation of duties, editing an approved sheet, and legacy reconciliation.
- Field applicability, visibility, the editorial line-count convention, content warnings and face claims. The required line ranges are confirmed.
- Club eligibility for non-students, membership applications and leadership, swimming's leadership title, and confirmation of the law club.
- Reputation scoring and ranking rules, academic rules, and the Gossip, relationships and messaging models.
