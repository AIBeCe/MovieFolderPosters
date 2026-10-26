# Saved-data migration validation

Date: 2026-10-26. Branch: `bugfix/storage-schema-migration`.
Implementation: `d685a93`; comparison baseline: `21a105d`.
Status: Issue-scoped validation complete; feature completion authorized.

## Verification

The approved schema migration, backup, retry, error presentation and menu integration were checked against
[the implementation requirements](STORAGE_SCHEMA_MIGRATION.md). Independent review passed with no remaining
Important or Critical findings. The redundant discarded startup read remains removed; `unknownCounts` remains
an instance property used by the individual collection summary flow.

Validation exposed one error-path defect: `DirectoryConfigurationService.safeCredentialError` converted a typed
migration-required error into a generic credential-storage failure. The main configuration view also replaced
its recovery explanation with generic text. An isolated regression using the real configuration service failed
its three guidance assertions before correction. Preserving the typed error and displaying its safe localized
explanation made the regression pass, including its Activity Log assertion. No preliminary startup read was added.

A fresh migration probe used existing private copies of historical data, copied again into a protected temporary
directory. It upgraded five records, decoded settings version 5, and validated four collections with all 380 folder
assessments retained. Postflight found all five records current. A repeated migration upgraded zero and skipped
five. It did not access live app data, movie contents, credentials, icons or extension registrations.

Coverage includes historical defaults and renamed keys, conflicting aliases, unsupported future versions,
malformed records, exact original-payload backups, backup/replacement failure safety, legacy-writer exclusion,
missing outcomes, pre-cancellation, partial-upgrade resumption, mixed current/legacy collection summaries,
menu cancellation/single-flight behavior and actionable Activity guidance.

## Unit and integration tests

| Final run | Result | Local raw evidence |
| --- | --- | --- |
| Common migration/configuration/outcomes and affected integration | 69 tests reported, 8 suites passed; 2 intentionally skipped tests | `/private/tmp/storage-migration-validation-common-final.log` |
| Host migration, real configuration loading, view model, coordinator, collection summaries, Finder, poster actions and Log | 118 tests, 8 suites passed; no skips | `/private/tmp/storage-migration-validation-host-final.log` |
| Historical-data private-copy probe | 5 upgraded; 4 collections / 380 folders validated; rerun 0 upgraded / 5 skipped | `/private/tmp/storage-migration-validation-copy-final.log` |
| Initial failing configuration-loading regression | Three guidance assertions failed before correction | `/private/tmp/storage-migration-validation-load-red.log` |

The two skipped Common cases are `processReaderObservesOnlyCompleteCommittedStates` and
`largeInventory32RecordCheckpointsReportEncodeAndEnvelopeCost`; these opt-in stress/performance probes were not
part of this issue-scoped run. Test totals above are reported by Swift Testing and are not summed across overlapping
runs. The whole project suite was not run. The earlier unrelated About image-size harness failures were not rerun.

SwiftPM used disposable writable caches and disabled nested sandboxing. The copy probe initially failed because
the default Clang module cache was not writable; explicit temporary module-cache paths resolved the environmental
failure. Final runs built and passed. These checks do not establish installed-app or live Finder qualification.

## SwiftLint

SwiftLint 0.65.1 ran with the unchanged repository `.swiftlint.yml`, `--no-cache`, JSON reporting and an explicit
list of all 36 Swift files affected by the implementation and validation changes. The same configuration checked
27 corresponding baseline files from `21a105d` in a temporary directory.

Final result: exit 0, zero errors and 26 warnings. Eighteen warnings match baseline rule, reason and source text.
The eight new or changed warnings are numerical size/complexity indicators:

| Location | Indicator |
| --- | --- |
| Activity failure mapping | Complexity 12 → 13; body length 52 → 61 |
| Settings conversion | New converter complexity 12 |
| Directory configuration service | File length 595 → 596 |
| Directory configuration tests | Type length 374 → 379 |
| Directory configuration service tests | File length 780 → 799; type length 393 → 412 |
| Collection processing store tests | Type length 327 → 329 |

These were reviewed for cohesion and responsibilities. The repository explicitly treats numerical thresholds as
indicators and prohibits splitting functions/types solely to satisfy them. No rule was suppressed or weakened.
New `async_without_await` and `statement_position` warnings found initially were corrected. Remaining baseline
line-length, import-order and parameter-count warnings were not expanded into unrelated cleanup.

Raw current/baseline JSON and diagnostics are under `/private/tmp/storage-migration-validation-lint-*`;
the exact file list is `/private/tmp/storage-migration-validation-swift-files.json`.

## Swift style guide

Applied the installed `swift-style-guide` skill to the affected Swift changes. Independent re-review passed after
DocC contracts/property documentation, guard spacing, return spacing and `else` placement were corrected.
The unnecessary `async` on a synchronous cancellation test was removed. No added Swift line exceeds 120 columns.
Style corrections preserve API, ownership, actor isolation and behavior. `git diff --check` passes.

## Remaining qualification limits

- No installed-app menu, keyboard, VoiceOver or live Finder cross-process migration qualification was performed.
- Mid-record cancellation is not directly injected; pre-cancellation and deterministic partial-upgrade retry are tested.
- Opaque low-level Persistence envelope failures retain safe generic storage-access guidance.
- The separate legacy directory-namespace migration remains offline; this feature upgrades schemas in the current namespace.
- Live user data and unrelated working-tree files remain untouched. No merge or push has occurred.
