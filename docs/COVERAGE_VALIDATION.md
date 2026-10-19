# Coverage validation — point 1

Approved: 2026-10-18. Validated: 2026-10-19.
Status: Point 1 complete and independently reviewed. Commit approved on 2026-10-19. Stop before point 2
(SwiftLint cleanup); integration into develop remains separately gated.

## Acceptance and measurement

Production executable-line coverage must be strictly greater than 90% for the complete application project
(host plus Finder extension) and for each local package: Network, FileSystem, Persistence, Log, and
MovieFolderCommon. Also report host and Finder separately so aggregate percentages cannot hide either target.
Tests, generated runners/resource accessors, manifests, and dependency source are not a component's production
denominator. Production files must not be removed or excluded to meet the threshold. Missing target/file data
fails the gate instead of being reported as complete coverage. Record exact covered/total executable lines.

Use compiler coverage exports, real isolated filesystem/persistence fixtures, and injected external-system
boundaries. Keep public production defaults, stored formats, and all permission, ownership, identity,
suppression, cancellation, and current-configuration checks. Never use user App Group data or credentials to
raise test coverage. Instrument AppDelegate in the standalone library harness by removing only the copied
`@main` attribute (not its source or executable lines). Finder production sources enter their own harness target.
Coverage proves executed lines, not native OS callback delivery, signed entitlement qualification, or correctness
of every branch. Those limits remain explicit.

## Repeatable validation

Run `rtk proxy bash scripts/test-coverage.sh` from the repository root. The command creates a new temporary artifact
directory, runs every package and the combined application harness, then writes `coverage.json` and returns a
nonzero status for failed tests, incomplete accounting, or any required threshold failure. Each component retains
its test log and compiler coverage export. `scripts/test-support/tests` tests the accounting and harness itself.

The compiler emits no executable source records for plain enum declarations or generic records containing only
stored properties. The reporter lists these files as declaration-only rather than inventing executable lines.
Its conservative classifier rejects explicit initializers, methods, computed properties, observers, and defaults;
missing data for such source fails validation. All compiler-reported executable lines remain in the denominator.

## Test boundaries and limitations

- Package tests use disposable stores, real temporary directories, and an injected Keychain backend. The live
  query attributes and noninteractive authentication policy remain unchanged.
- Host action tests retain real authorization leases, identity/configuration fencing, outcome persistence, and
  poster processing. Injected credentials, provider responses, storage locations, and bookmark creation keep tests
  away from user credentials and configured collections.
- AppDelegate tests use an injected application root and modal-alert presenter. Live startup and modal defaults
  remain unchanged. Tests inspect actual menus, windows, URL routing, and sanitized failure messages.
- Installation tests inspect temporary bundle metadata and static signatures without launching a bundle, and
  decode receipts in real temporary stores. Live Bundle.main and App Group wrappers remain counted.
- Finder tests retain the principal-class adapter and exercise its runtime, leases, cancellation fencing, and
  actual Objective-C menu target/action dispatch with isolated dependencies.
- SwiftPM tests inspect actual configuration report windows and contents. Native sheet attachment, completion
  delivery, Finder callback delivery, signed security-scope grants, and persistent Finder icons remain separate
  integration/manual qualifications. These tests do not establish those observations.

## Measured starting point

| Component | Covered/executable lines | Coverage |
| --- | --- | --- |
| Host subset excluding AppDelegate and Finder | 2389/3426 | 69.73% — incomplete project coverage |
| Network | 320/347 | 92.22% |
| FileSystem | 1134/1268 | 89.43% |
| Persistence | 326/356 | 91.57% |
| Log | 146/148 | 98.65% |
| MovieFolderCommon | 1973/2300 | 85.78% |

Starting artifacts: `/private/tmp/mfp-coverage-baseline-7EN76E`. Common's two opt-in process/scale probes were
not enabled in this baseline; they must be distinguished from executed tests in later records.

## Work and ownership

- Root: reusable application harness including host/Finder, coverage collection/reporting/gate, documentation,
  integration decisions, final validation. Reporter tests cover exact threshold, missing/incomplete data,
  duplicate source handling, source-root membership, path mapping, and malformed reports.
- Package implementation: FileSystem/Common behavioral gaps and narrow internal environment/Keychain seams.
- Host implementation: coordinator/view/service behavior, isolated action authorization/provider environments,
  AppDelegate bootstrap routes and errors. No real app loop or user-store startup in tests.
- Finder implementation: retain actual FIFinderSync adapter; isolate its runtime and selection/platform boundaries
  so real orchestration can be tested safely with controlled callbacks and storage.
- Independent review after integration, with persistent ownership through corrections. No next recovery-policy
  point, lint cleanup, issue closure, commit, merge, or push is included.

## Verification ledger

- [x] Production behavior tests and safe dependency seams implemented.
- [x] Complete collection and exact per-component coverage gate tested.
- [x] Project (host plus Finder aggregate) and all five packages exceed 90% with full source accounting;
  host and Finder percentages are reported separately.
- [x] Relevant regressions, signed builds, final scoped lint assessment, and independent review complete.
- [x] User approval to commit.

## Final verification — 2026-10-19

The fresh `scripts/test-coverage.sh` run exited successfully with `passed: true`, no missing executable sources,
and the following compiler-reported results:

| Component | Covered/executable lines | Coverage |
| --- | --- | --- |
| Project — host plus Finder | 3499/3873 | 90.34% |
| Host — reported separately | 3263/3552 | 91.86% |
| Finder — reported separately, fully counted above | 236/321 | 73.52% |
| Network | 320/347 | 92.22% |
| FileSystem | 1147/1268 | 90.46% |
| Persistence | 326/356 | 91.57% |
| Log | 146/148 | 98.65% |
| MovieFolderCommon | 2100/2331 | 90.09% |

Artifacts are under
`/private/var/folders/h0/423hyq0d1mj429_q6zhqkw9r0000gn/T/MovieFolderPosters-Coverage.ywMT4J`:
`coverage.json`, `manifest.json`, and per-component `tests.log` and compiler exports. The application run passed
151 Swift Testing tests across 20 suites. Package runs reported FileSystem 62, Log 13, Network 21, Persistence 13,
and Common 115 Swift Testing tests plus 44 XCTest tests. Common's two explicitly opt-in process/scale probes were
skipped; they are not claimed as executed checks. The coverage tooling's 15 Python tests passed.

Independent package, host, Finder, and coverage-tooling reviews returned PASS. Signed native Debug
build-for-testing and Release build passed on the final sources; both app bundles passed
`codesign --verify --deep --strict`. These builds do not establish native runtime qualification.
Final build logs are `/private/tmp/mfp-coverage-native-debug-verified.log` and
`/private/tmp/mfp-coverage-native-release-verified.log`.

Final repository SwiftLint assessment reports 159 violations (153 warnings, 6 errors), matching a clean HEAD
snapshot's rule/file counts. New violations introduced by this point were fixed without changing rules,
thresholds, or exclusions. The pre-existing root-loading function length warning remains; its body is smaller
than at HEAD. The remaining lint baseline belongs to point 2 and is not reported as clean.
Lint evidence: `/private/tmp/mfp-coverage-lint-final.json` and
`/private/tmp/mfp-coverage-lint-baseline.json`.

The user subsequently approved committing point 1. Merge, push, issue closure, and point 2 implementation remain
outside this completed point.

Point 1 was committed as `548d278`. Subsequent point 2 refactoring and its updated coverage measurements are
recorded in [SwiftLint validation](SWIFTLINT_VALIDATION.md).
