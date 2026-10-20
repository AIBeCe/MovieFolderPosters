# Observed collection processing — validation

Date: 2026-10-20. Branch: `bugfix/observed-processing-resume`. Implementation commit: `ea8b5a1`.
Status: Automated validation passed; installed-extension and user-collection qualification remains outstanding.

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
