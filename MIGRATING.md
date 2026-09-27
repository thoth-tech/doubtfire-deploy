
# Migrating between Doubtfire Versions

## OnTrack 11.0.x combined all-features release (24 August 2026)

This dossier applies only to the API revision pinned in `HANDOVER.md`. The
expected final Rails schema version is `20260824000003`; `production/verify.sh`
fails if the running database does not match it. Re-audit this matrix if the API
revision or migration set changes.

The supported paths are a fresh empty database or an exact prior release/schema
that the receiving institution records in the change manifest and successfully
rehearses from a production-sized isolated restore. This dossier does not claim
that an arbitrary older OnTrack database can upgrade directly. Any unrecorded
source version, skipped historical migration, vendor fork, or schema drift is a
separate blocked migration project until its full path and rollback have been
reviewed and rehearsed.

The production stack runs migrations as a one-shot service before starting the
new API and workers. The hardened web is staged first for authentication
callback compatibility. Do not run multiple migration jobs, use `db:populate`,
or run any demo seed task against production.

### Migration matrix

| Version | Change and expected data work | Availability and rollback classification |
| --- | --- | --- |
| `20260722000001` | Creates `notifications` and its user/read index. | Additive. An application rollback can leave the table in place; reversing it deletes notification history. |
| `20260802000001` | Adds required notification `event`, backfills any existing rows to `legacy`, adds an index, then removes the write default. | May alter/lock `notifications`. Do not roll back to an intermediate app that writes notifications without `event`. Reversal deletes event provenance. |
| `20260802000002` | Widens notification `message` from `VARCHAR(255)` to `TEXT`. | The alter may rebuild/lock the table. Forward schema is compatible with older readers. Reversal is lossy or can fail once a message exceeds 255 characters. |
| `20260802000003` | Creates `push_subscriptions` and a unique endpoint index. | Additive. Reversal deletes every browser subscription and forces opt-in again. |
| `20260809153000` | Creates privacy-internal `peer_progress_snapshots` and its unique unit/task/grade index. | Additive. Reversal deletes aggregates; the student endpoint must remain disabled/fail closed until regenerated. |
| `20260810033824` | Adds `units.peer_progress_enabled`, default `false`, not null. | Safe default keeps all existing units opted out. The alter may lock `units`. Reversal loses unit opt-in decisions. |
| `20260818160804` | Adds `projects.target_grade_changed_at`, backfills every existing project to migration time, retains a database current-time default, then enforces not null. | The bulk update may lock or generate substantial redo on a large `projects` table. The retained default protects older writers. Reversal loses freshness history and requires new PPI aggregation after re-upgrade. |
| `20260824000001` | Adds task-notification tracking/default/index plus notification dedupe key, delivery timestamp and unique user/dedupe index. | Alters `task_definitions` and `notifications`. Additive to old readers. Reversal loses dedupe/delivery state and can cause duplicate mail after re-upgrade. |
| `20260824000002` | Repairs/retains the database default for `projects.target_grade_changed_at` on installations that previously recorded an older form of the preceding migration. | Idempotent metadata repair with no row backfill. Its down path intentionally preserves the compatibility default. |
| `20260824000003` | Adds nullable, internal `peer_progress_snapshots.submitted_count` and `peer_progress_snapshots.status_counts` JSON, plus `users.display_peer_progress` with database default `true` and `NOT NULL`. Exact counts let the student API subtract the authenticated reader before privacy thresholding and quantisation. Existing snapshots keep their legacy stored percentage for older readers, but the new API deliberately withholds compact and detailed output until reaggregation fills both exact fields. Existing and future users start with the requested display preference enabled and may persist `false` through Profile. | Additive for old readers/writers, but the `users` alter/default backfill may lock a large table and must be measured. Reaggregate every approved PPI unit before acceptance. Prefer keeping the forward schema during application rollback. Reversal removes peer-only aggregate inputs and erases every explicit user opt-out, so re-upgrade would default those users on again unless the preference is separately restored. |

No migration intentionally deletes an existing pre-release application table or
column. Database reversal is nevertheless not the preferred application
rollback: several `down` paths destroy new feature state, and the message-width
reversal is explicitly lossy. For a compatible previous release, normally keep
the forward schema and roll back application images during a maintenance window.
Use database restore only when the reviewed previous application is not forward-
schema compatible or data integrity is in doubt.

### Required rehearsal and evidence

Before the change window, restore a recent production-sized recovery set to an
isolated host using `DEPLOYING.md`, then record:

- exact source/target schema versions and row counts for `projects`,
  `task_definitions`, `notifications`, `units` and `users`;
- table sizes, free disk space, migration start/finish time, longest metadata or
  row lock, database CPU/IO/redo growth, and any blocked query;
- counts before/after the project timestamp backfill and confirmation that no
  resulting value is null;
- confirmation that existing units remain PPI-disabled, notification dedupe
  indexes are valid, no user has a null PPI display preference, the new API
  suppresses legacy snapshots whose exact count fields are still null, and no
  synthetic/demo records were introduced;
- `rails db:abort_if_pending_migrations`, `production/verify.sh`, and application
  smoke-test results; and
- whether the measured outage fits the institution's approved maintenance
  window and RTO.

Fresh-install and simulated previously-recorded migration repair tests passed
against MariaDB 12.3 during branch validation. That proves migration semantics,
not production-scale duration; the receiving team's rehearsal remains a release
gate.

Immediately before migration, create the consistent database/student-work
recovery set described in `DEPLOYING.md`, verify its checksums and restore-test
record, drain traffic, and check for pending/long-running database work. After
migration, require schema `20260824000003`, inspect Sidekiq queues/retries, queue
the first PPI aggregation only for an approved unit, verify its exact aggregate
fields are populated without printing them, and complete every manual gate in
`HANDOVER.md`.

## Version 5 to Version 6

Version 6 changed database encryption, so a direct upgrade cannot preserve old
sessions without a dedicated token migration. The former procedure in this file
wrote every live bearer token as executable plaintext under the application log
directory. That procedure is not approved for use: it did not guarantee mode
0600, encrypted transport or storage, safe escaping, deletion, expiry or
rotation.

The supported safe default is to skip token preservation and require every user
to sign in again after migration. If preserving sessions is a business
requirement, stop the release until the security and identity owners approve and
test a one-time migration tool that writes outside logs and routine backups,
uses mode 0600 plus encrypted transfer/storage, records no token values in
evidence, verifies import counts without printing credentials, and securely
deletes or cryptographically destroys the export immediately after acceptance.
Rotate or expire the migrated tokens on an approved schedule.

Ensure there is enough space to recreate the database (up to twice its current
size during the migration), take and restore-test a complete backup, migrate in
a maintenance window, and verify that all prior sessions are invalid when using
the safe default.

## Version 4 to Version 5

Migration from version 4 to version 5 does not require any specific custom migration. Database updates will be applied through rails migrations.
