# Saved-data version migration

Status: Implemented, validated and integrated into `develop` on 2026-10-26.
Independent implementation and validation reviews PASS.
Feature branch: `bugfix/storage-schema-migration`; baseline: `21a105d`; implementation: `d685a93`;
validation: `5eb86b1`. Validation evidence is in [the validation report](STORAGE_SCHEMA_MIGRATION_VALIDATION.md).
Live app-data migration, installed-app accessibility checks and extension registration were not part of validation.

## Problem and approved behavior

Renamed matching settings no longer decode existing collection records. A copied real record fails at
`context.identificationPolicy.requiresReleaseYearForAutomaticMatching`; converting the historical field name
makes both affected copied records decode and validate (37 and 334 folders). The enclosing historical application
`identificationPolicy` also needs explicit migration rather than silent fallback to default matching choices.

- Provide an independent native menu command, “Migrate Saved Data…”, available even when configuration cannot open.
- Startup/normal readers detect outdated data and explain that processing is paused until the command is run.
  Normal reads never perform migration. A command invocation performs migration away from the main actor.
- One small Common migration service owns version routing, historical conversion, original-payload backups,
  validation and replacement. Reuse existing Persistence record locks and atomic writes; no new module/framework.
- Settings versions 1–4 upgrade to version 5; collection processing schema 1 upgrades to schema 2. Current domain
  models read/write the current schema. Preserve established defaults, identifiers, authorization/processing/history
  revisions, settings, collection outcomes, suppression and ownership evidence.
- Settings upgrade first under its existing record access. Version 5 fences older configuration writers and final
  icon checks which reject unsupported versions. Test older in-flight writer behavior; do not assume a new lock
  can stop an older process that does not participate in it.
- Each outdated record is backed up before validated atomic replacement. Backups use a separate protected
  `MigrationBackups` Persistence namespace, never the pruned collection-results namespace. Repeated runs preserve
  original backups; changed historical payloads never silently replace a different backup.
- Records migrate independently. Already-current records are skipped. If interrupted after settings or some
  collections commit, rerunning resumes remaining old records; no all-record rollback or progress database.
- Unknown future versions, conflicting fields, malformed data, busy locks, backup failures and write failures have
  distinct safe messages. Never erase a record, reset state, or substitute defaults after corruption.
- Migrate all existing records for configured collections; leave absent records absent and unrelated histories,
  artwork caches, bookmarks/credential stores and movie content untouched. Settings retain their existing bookmark
  bytes; no authorization or credential generation rotates solely for migration.
- Report actual upgraded/unchanged record counts. “Already up to date” is explicit. Partial completion remains
  visible and retryable; do not imply every record migrated after a later failure.
- Successful migration refreshes host configuration and notifies Finder to reload committed settings/results.
  No timers, new daemons, watchers, network request or new credential operation.
- Clear app/Log errors distinguish migration-required, a newer incompatible app format, invalid saved data,
  contention and actual I/O/backup failure. Do not tell users to fix folder permissions for a decoding problem.

## Ownership and implementation

- Common worker: migration files/tests, settings and processing models/repositories.
- Root: application menu/routing, independent command service/presentation, environment composition,
  Finder/Log error classification and corresponding host tests.
- Architecture reviewer: bounded storage/old-writer/interruption critique; independent implementation review follows.
- Apply swift-style-guide and meaningful Swift Testing RED→GREEN checks. Focused implementation checks only;
  The implementation phase used focused checks; formal validation results are recorded below and in the validation report.

## Delivered command and error behavior

The application menu contains **Migrate Saved Data…** beside Settings. The confirmation explains backup and
scope. The operation runs on a utility task and is single-flight. It can run when configuration failed to open;
Cancel does not invoke storage. Completion shows actual upgraded, already-current and absent-result counts.
Failure explains the affected data kind, the next action and that earlier committed upgrades/recovery copies
remain available. Successful or partial work publishes a settings reload hint only after storage accesses release.

Configuration loading rejects older settings schemas and records migration guidance in Activity; the redundant
preliminary startup read was removed by review decision. Existing schema-5 settings remain usable even when one collection has old or invalid results: the asynchronous per-root projection
retains that collection's recovery guidance, while healthy collections retain their counts. The Finder and early
host startup failure boundaries record typed recovery guidance in Activity. There is no automatic schema upgrade
from a normal reader and no all-root results scan on the main-actor startup callback.

Current settings and processing models accept schema 5 and 2 respectively. Conversion/defaulting of older formats
is confined to the migration service; current decoders reject unconverted aliases instead of interpreting them.
Explicit wire-key strings protect the affected current fields from automatic Swift symbol renames.

## Focused implementation evidence

These are the earlier implementation coherence checks; final issue-scoped validation appears in the linked report.
Counts overlap and must not be summed into a unique test total.

| Check | Result | Raw local evidence |
| --- | --- | --- |
| Common configuration, outcomes and migration integration | 70 tests, 6 suites passed | `/private/tmp/storage-migration-core-finish.log` |
| Migration and failure/backup focused runs | 15 and 16 tests passed in overlapping scopes | `/private/tmp/storage-migration-core-edge.log`, `/private/tmp/storage-migration-core-failure-cases.log` |
| Common final formatting follow-up | 57 tests, 7 suites passed | `/private/tmp/storage-migration-core-stylecheck.log` |
| Final migration and persisted-wire-key follow-up | 20 tests, 6 suites passed | `/private/tmp/storage-migration-final-common.log` |
| Host menu/routing, collection summaries, Finder, manual actions and Log | 81 tests, 6 suites passed | `/private/tmp/storage-migration-host-final.log` |
| Final stopped-run guidance, startup Log and mixed-collection follow-up | 5 tests, 3 suites passed | `/private/tmp/storage-migration-host-final-followup.log` |
| Real saved-data private-copy probe | 5 records upgraded; 4 collections and all 380 folder assessments validated; repeated migration upgraded 0 and skipped 5 | `/private/tmp/storage-migration-real-copy2.log` |

The original absence of a migration menu and misleading signing advice were reproduced in two failing host tests
before the menu/error changes. The typed Activity migration-message regression also failed before classification
was implemented. Core coverage includes legacy defaults actually omitted from old payloads, matching-key conflicts,
future versions, original-byte backups, failure before replacement, settings-lease exclusion of an older writer,
pre-cancellation, missing outcomes, idempotence and resumption after settings committed but an outcome was busy.

Independent review resolved I1 (global configuration block from eager root reads), I2 (missing startup Activity
failure) and I3 (duplicate CodingKeys introduced during final integration). The same review owner confirmed final
PASS with no remaining Important/Critical findings. `git diff --check` passes.

## Limits and next phase

- Live shared app data, collection icons, movie contents, credentials and extension registrations were not modified.
  The real-data probe operated on protected temporary copies and preserved the original source records.
- Mid-record cancellation is not directly injected; pre-cancellation and deterministic partial-upgrade/resume are
  tested. Existing Persistence atomic replacement and source leases remain the commit mechanism.
- Low-level Persistence envelope failures are opaque to Common and still receive a safe storage-access message;
  app-schema migration-required, future-version, malformed-payload and conflict failures are distinguished.
- The existing legacy directory-namespace migration remains an offline operation requiring stopped older
  processes; this command upgrades record schemas in the supported current namespace.
- A broader AppDelegate harness run encountered two unrelated About icon-size assertions (128 versus 1254).
  Migration-specific tests and the final affected scopes pass; icon-loading source was not changed.
- SwiftPM nested sandboxing failed in this environment. Focused tests use `--disable-sandbox` and writable caches.
  A temporary-copy probe path initially failed a pinned Persistence directory open; using the native temporary
  directory succeeded. Neither failure changed production app data.
- Installed-app menu, keyboard and VoiceOver checks and live Finder upgrade qualification remain unperformed.
  See the validation report for completed issue-scoped tests, SwiftLint and style review.

Unrelated untracked Xcode/build files remain untouched. The feature was fast-forwarded into `develop`; release and
extension registration remain separate work.

## Applied review decisions

The user completed the review and authorized applying the agreed corrections.

- Point 1: The user approved deleting the redundant startup `_ = try repository.read()` call; that line is removed.
- Point 2: Discarded-result audit discussed; no further changes authorized.
- Point 3: Keep `@objc` on AppKit target–action handlers; no change requested.
- Point 4: Applied. `CollectionSummaryService.unknownCounts` is an instance computed property, and all ten
  type-qualified references now use `unknownCounts`. The unavailable-count fallback belongs to each collection's
  summary flow; lack of instance-property access alone does not justify a type-level member. Per-collection
  calculation, unavailable-value behavior and naming are preserved.

Review-correction check: `CollectionSummaryCoverageTests` passed all 7 tests, including mixed current/legacy
collections and unavailable-count handling (`/private/tmp/storage-migration-review-corrections.log`).
`git diff --check` passed. These implementation corrections are included in `d685a93`; formal validation is
recorded in [the validation report](STORAGE_SCHEMA_MIGRATION_VALIDATION.md).
