# HU-009F-B migration and HU-009F-C contract handoff

## Read-only inventory before approval

Run against a secure restore first. Keep results with the operator. The inventory contains counts only. For a synthetic upgrade rehearsal, use a disposable database containing exactly the HU-009E migrations and run `psql -X -v ON_ERROR_STOP=1 -f tests/fixtures/character-policy-legacy.sql`. This fixture applies both new migrations and asserts preservation of historical data.

```sql
with refused as (
  select character_id, count(*) as total
  from private.character_reviews where decision = 'rejected' group by character_id
)
select c.validation_status, c.use_status, coalesce(r.total, 0) as lifetime_refusals,
       count(*) as characters
from private.characters c left join refused r on r.character_id = c.id
group by 1, 2, 3 order by 1, 2, 3;

select count(*) as legacy_houses_from_corrections
from private.characters c join private.character_reviews r on r.id = c.house_review_id
where r.decision = 'changes_requested';

select count(*) as incomplete_legacy_submissions
from private.characters c
left join public.character_profiles p on p.character_id = c.id
left join private.character_sheets s on s.character_id = c.id
where c.validation_status = 'submitted' and (
  p.first_name is null or p.last_name is null or s.age is null or s.birth_date is null
  or s.face_claim is null or s.physical_description is null or s.personality is null or s.backstory is null
  or (c.kind = 'student' and c.program_id is null)
  or (c.kind in ('teacher', 'staff_member') and s.occupation is null));
```

Check the ten migration versions through HU-009E, take a recoverable backup, confirm the expected threshold-archive count and reconcile any unexpected classifications before applying. Rehearse on a staged restore with representative data. Retain record counts, historical House references and suspension counts for comparison.

## Applied data policy

Apply the two migration versions in order as separate transactions. The first adds the capability enum value. PostgreSQL requires the enum addition to commit before the next migration uses it. The second changes the character policy and installs the reopening boundary atomically. It changes only character lifecycle data and permissions attached to this workflow.

Every legacy character defaults to `inline`. The backfill counts immutable `rejected` rows. A character currently `rejected` with at least three historical refusals becomes archived, dated by its current refusal. Other legacy sheets retain their disposition, including approved characters with three or more historical refusals. A later refusal of such an in-progress sheet archives it. Existing submitted sheets remain reviewable and are evaluated under the new submission checks the next time they are submitted. Existing decisions have null examined revision and no external evidence. All House, decision, owner, character and use references survive. Backfilled character rows rotate their revision through the existing trigger. Compare counts and invoke the normal app contracts after rehearsal.

## Coordinated rollout

1. Confirm the inventory, business decisions, staging backup and rollout authorization. Run the migrations, PostgreSQL tests and type regeneration on the staged copy.
2. Update HU-009F-C's strict Zod schemas and verify the backend and frontend together. Keep character and review UI unavailable during any mismatch window. Deploy schema and backend as a coordinated change. The previous backend rejects the new strict RPC response fields.
3. Check `/me`, capacity, owner and reviewer actions, archive isolation, stale revisions and PostgREST exposure. Separately authorize any future operator grants and frontend activation.
4. If rollback is needed, disable the affected UI and mutation entry points first. Keep lifecycle records and evidence. Fix forward with a compatible API on the migrated schema, or rehearse a coordinated database restoration with an explicit write cutover and recovery point. Rolling only the backend back produces the same strict-contract incompatibility. Dropping archive data or restoring a stale snapshot would discard later audit records.

## Frontend contract changes

| Surface                      | HU-009F-C requirements                                                                                                                                                                                                                                                                                                                            |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Player character list/detail | Accept `sheetMode`, `refusalCount`, nullable `archivedAt` and `actions` containing `canEdit`, `canSubmit`, `canRequestReopening`. Full detail adds nullable `externalUrl`. Use actions for controls. A rejected sheet can be current and editable. Server authorization remains authoritative.                                                    |
| Create, edit and submit      | Default to inline. Add a sheet-mode selector and clear the external link on transition back to inline. Preserve incomplete drafts and omitted fields. Display explicit nonblank line counts and keep revision handling. Open approved-provider links with no referrer and a safe new-tab relationship.                                            |
| Owner archive                | List separately via `GET /api/v1/characters/archives`. Existing owned detail and review history remain available. Exclude archives from the current character view.                                                                                                                                                                               |
| Staff review                 | Accept `refusalCount` and `archivedAt` in mutation results and `examinedRevision`, `archivedCharacter` and `externalEvidence` in reviews. Request explicit manual attestation on external sheets. Only show new House selection on student approval. After a mutation with an uncertain result, reload the sheet and history before acting again. |
| Reopening                    | Render owner and staff timelines using the new `reopening-requests` routes. Use one generated UUID for the same owner request, reload on conflict, and avoid retrying a completed decision. A request at capacity is valid. Acceptance can fail at capacity without consuming or resolving the pending request.                                   |
| Staff archives and context   | Gate staff archive UI on `characters.reopen`, independently of `characters.review`. Use paginated `GET /api/v1/staff/characters/archives` and `GET /api/v1/staff/characters/{characterId}/archive`. Add `characters.reopen` to the context schema. `/me` and bootstrap share the current, nonarchived character projection.                       |

An archived sheet can be replaced by a new draft if the player has capacity. The workflow cannot reliably infer that two fictional characters or external documents are the same. A future enforcement policy needs a staff decision and a separate threat assessment. External document changes and lost access after review remain manually handled.
