# Observed collection processing — validation

Date: 2026-10-20. Branch: `bugfix/observed-processing-resume`. Implementation commit: `ea8b5a1`.
Status: This is the 2026-10-20 snapshot. See the 2026-10-22 follow-up below for the current branch.

## Verification

- A root-only directory source queues a coalesced follow-up visit when a direct child is added to an observed local
  collection. The local directory event integration test passed. Work remains serialized and scoped to configured,
  authorized roots; the processor rechecks root identity and mutation authorization before icon writes.
- A provider backoff result returns its recorded deadline to the scheduler. A still-observed root receives a one-shot
  continuation at that deadline, including when the deadline expires before the prior visit finishes. Closing the
  observation, removing the root during reload, or stopping the extension cancels deferred work. Unique identifiers
  reject callbacks from superseded monitors and retry tasks.
- The disposable cross-process recovery probe passed killed-writer lock release, durable recovery mode, stale-process
  fencing, and explicit resume. Signed Debug build-for-testing and Release build passed; strict signature verification
  passed for each built host app and Finder extension.
- Native Finder callback delivery in an installed extension, actual poster assignment on the user's Hangar51
  collection, and System Settings entry cleanup were not performed. The new extension was not registered. Those live
  observations cannot be inferred from isolated tests or successful builds.

## Unit tests and coverage

`scripts/test-coverage.sh` passed with complete production-source accounting and no missing executable sources.
All five local packages and the combined host/Finder harness passed: 184 application Swift Testing cases, 173 Common
Swift Testing cases, 44 Common XCTest cases, 62 FileSystem, 21 Network, 13 Persistence, and 13 Log cases. Two opt-in
Common process/scale cases were skipped by the default suite. The coverage tooling's 16 Python unit tests also passed.

| Component | Covered/executable lines | Coverage |
| --- | ---: | ---: |
| Project, host plus Finder | 4168/4628 | 90.06% |
| Host | 3921/4293 | 91.33% |
| Finder, reported separately | 247/335 | 73.73% |
| MovieFolderCommon | 2776/3017 | 92.01% |
| FileSystem | 1168/1289 | 90.61% |
| Network | 323/351 | 92.02% |
| Persistence | 331/361 | 91.69% |
| Log | 138/140 | 98.57% |

The modified `DirectoryObservationScheduler.swift` received 209/212 executable-line coverage. Coverage artifacts are
under `/private/var/folders/h0/423hyq0d1mj429_q6zhqkw9r0000gn/T/MovieFolderPosters-Coverage.ShyuYq`.

## SwiftLint and style

`swiftlint lint --config .swiftlint.yml --no-cache` reported zero violations and zero serious findings in 148 files.
The installed `swift-style-guide` was applied to the changed Swift code. Its required formatting, naming, access,
DocC, optional-handling, and closure-capture rules had no findings. Changed Swift lines stay within 120 columns.
The Debug test build emitted weak-variable and unused-result warnings in unchanged test files, plus Xcode's skipped
App Intents metadata messages; the Release build emitted only the metadata messages. No SwiftLint rules were weakened.

Validation logs: `/private/tmp/mfp-validation-coverage.log`, `/private/tmp/mfp-validation-swiftlint.log`,
`/private/tmp/mfp-validation-recovery-process.log`, `/private/tmp/mfp-validation-native-debug.log`, and
`/private/tmp/mfp-validation-native-release.log`.

## Follow-up validation — 2026-10-22

The current `bugfix/observed-processing-resume` branch includes the observed-root event and retry changes,
database-code suffix parsing and cached-decision migration, dismissible Processing Details and Unresolved Results
sheets, and Finder menu/Choose Movie dismissal repairs. Validation found and corrected a cached-poster rewrite that
discarded the parser revision, an overlong results-view function, and a test assertion that still forbade the newly
required Processing Details Close button. These three corrections remain uncommitted pending Validation Phase approval.

- Verification: The real temporary-root directory event test, retry-deadline and cancellation tests, cached parser
  migration tests, AppKit sheet/control tests, and Finder menu target/dispatch tests passed. The disposable recovery
  process probe passed killed-writer lock release, durable recovery mode, stale-process fencing, and explicit resume.
  Signed Debug `build-for-testing` and Release `build` succeeded. Escalated `codesign --verify --deep --strict` passed
  for both app bundles and their embedded Finder extensions; sandboxed trust-service verification alone returned
  `CSSMERR_TP_NOT_TRUSTED`.
- Unit tests and coverage: All six local packages and the combined host/Finder harness passed. The application
  Swift Testing run passed 185 tests in 24 suites; MovieFolderCommon passed 174 tests with two opt-in process/scale
  tests skipped. The coverage tooling's 16 Python tests also passed. Complete production-source accounting passed
  the project coverage gate at 4,211/4,675 executable lines (90.07%); host coverage was 91.40%, Finder 73.24%,
  MovieFolderCommon 91.82%, and MovieFolderParsing 100%.
- SwiftLint: `swiftlint lint --config .swiftlint.yml --no-cache` found zero violations and zero serious findings in
  151 files. No rules were changed or suppressed.
- Swift style: The installed `swift-style-guide` was applied to affected Swift code. The validation corrections
  preserve naming, DocC, optional handling, ownership, and the repository's 120-column layout. No remaining
  required-style deviation was identified.

The latest extension was not installed or registered, and the user's collections were not changed. Therefore this
run does not establish live Finder callback delivery, poster assignment on those collections, or System Settings
registration cleanup. Xcode emitted a destination warning that the scheme's supported platforms list was empty;
both requested arm64 build actions still succeeded without compiler warnings or errors.

Current logs: `/private/tmp/moviefolderposters-test-coverage-final.log`,
`/private/tmp/moviefolderposters-swiftlint-final.log`, `/private/tmp/moviefolderposters-debug-build-final.log`,
`/private/tmp/moviefolderposters-release-build-final.log`, and
`/private/tmp/moviefolderposters-codesign-{debug,release}-escalated.log`.
