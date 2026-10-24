# Processing recovery — issue #4

Status: implementation, independent review, and final validation complete on 2026-10-20.
Recovery was committed as `008a6f3` and fast-forwarded into local `develop` on 2026-10-20.
The user authorized feature completion and a separate documentation commit on `develop`. No push or issue closure
was performed; native qualification limits below remain unchanged.
The preceding style-only changes were committed separately as `58e6d33`.

## Required behavior

- Determine automatic eligibility from the unchanged folder's persisted reason, not the presence of a retry date.
  Confirmed Not found and Several matches remain manual across reloads and restarts. Parsing and missing artwork
  require explicit action or changed folder evidence; incomplete search gets a fresh assessment after its delay.
- Retry temporary connectivity, server, and interrupted failures only on a later authorized invocation. Authentication
  requires a changed credential. Throttling honors a shared bounded Retry-After deadline across roots/processes.
- Reassess reasonless legacy unresolved records once, bypassing their obsolete delay and inconclusive query cache.
  Persist the classification and recover safely from interruption. Preserve verified installed icons and unrelated data.
- Keep all existing access, identity, ownership, suppression, cancellation, and settings-generation checks.
- Separate freshness from work counts: Needs processing, Waiting to retry, Needs manual resolution, Needs reassessment,
  and Complete. Mixed conditions remain visible; incomplete/unknown/stale evidence cannot claim completion.
- `--recovery-mode` enables a durable shared gate before processing composition. Configuration and Log remain usable.
  Participating processes recheck the gate at provider admission and immediately before every icon mutation.
  Already-admitted requests may finish; their responses cannot authorize later writes while recovery mode is enabled.
  Enabling the gate serializes with synchronous icon mutations. Disabling it authorizes no automatic replay.
- Issue #4 introduced no watcher, timer, polling loop, daemon, new package, or movie-content mutation. The later
  observed-collection fix adds a root-directory event source and a one-shot retry for eligible folder or provider
  deadlines only while Finder continues observing that configured root; the recovery service and its admission rules
  are unchanged.

## Integration contracts

Add a narrow in-process `ProcessingRecoveryService` in MovieFolderCommon, backed by an independent versioned
record in shared App Group storage. Existing `PersistenceAccess` values provide atomic updates and cross-process
exclusive access.
Unreadable, corrupt, unsupported, or contended gate state fails closed. No settings/result/cache clearing is used.

```swift
public init(store: PersistenceStore, now: @escaping @Sendable () -> Date = Date.init)
public func read() throws -> ProcessingRecoverySnapshot
public func setRecoveryModeEnabled(_ enabled: Bool) throws
public func validateProcessingAllowed() throws
public func acquireProcessingAccess() throws -> PersistenceAccess
```

`ProcessingRecoverySnapshot.isRecoveryModeEnabled` supports the host controls. Provider admission and failure recording
belong to this same service. Store only allowlisted failure categories, bounded deadlines, and bounded digests of
rejected credentials; never store credentials, raw provider errors, or movie/user paths.

`RecoveryMovieMetadataProvider(provider:recovery:credential:)` wraps the existing metadata protocol for both search
and artwork, checks shared admission before each request, and records qualifying provider failures before returning.
Authentication blocks the same credential until changed; new credentials do not clear provider throttling.
Repeated 429 responses cannot shorten an existing deadline. Interpret seconds and HTTP dates; clamp invalid/missing
values to the bounded fallback. Networking remains outside persistence locks.

`MovieFolderEnvironment.makeProcessingRecoveryService()` opens the dedicated shared namespace. Production Finder
and host action composition must inject both the wrapped provider and recovery coordinator into MovieFolderProcessor.
Its initializer gains a defaulted optional `recovery` collaborator for existing isolated callers. All automatic/manual
icon mutation paths hold the recovery lease through their existing synchronous, identity-checked write boundary.

## Work and ownership

1. Processor: eligibility and reason mapping, interruption/legacy cache handling, recorded outcomes, gate checks,
   mutation fencing, and meaningful red/green regression tests. Own processor extensions and folder-reason models.
2. Shared coordination: durable recovery gate/provider policy, metadata wrapper, environment factory, cross-instance
   storage tests, auth/throttle/error classification, and mutation fencing tests. Own new recovery service files.
3. Host/Finder integration and presentation: compose live safeguards, recovery launch/control/error presentation,
   work projection and table/details labels, mixed/unknown tests, and entrypoint safety regressions.
4. Root: architecture/integration, independent review, complete-source coverage gate above 90%, final SwiftLint,
   signed native builds, durable documentation, and the user-authorized local GitFlow completion.

Apply the Swift style and Swift Testing skills. Use TDD where meaningful; record actual red/green observations.
Preserve established protocol delegates and weak ownership; do not introduce closure-property callbacks.

## Acceptance and verification ledger

- [x] 401/403, credential change, connectivity, invalid responses, server errors, and changing Retry-After.
- [x] Cross-instance shared backoff, concurrent updates, corrupt/unsupported storage, and no in-lock networking.
- [x] Confirmed manual outcomes across visits/reload/restart; legacy one-time reassessment and fresh query evidence.
- [x] Cancellation/process-loss resume with no repeated verified writes; current safety checks remain authoritative.
- [x] Recovery launch, cached provider/processor instances, direct manual searches, and all icon mutation paths gated.
- [x] Mixed pending/manual/retry/reassessment and unknown/stale inventories never imply Complete.
- [x] Independent reviews pass, no unresolved blocking findings, full tests/coverage/lint/native builds pass.
- [x] Update tracking/roadmap/policy documentation with implemented scope and unperformed native qualification.

Native Finder callback delivery, real network availability, signed security-scope grants, and persistent icon behavior
require separate native observations. Unit tests and builds must not be presented as proving those observations.

## Implemented policy and safety details

- Authentication is credential-dependent, not time-dependent. A version 2 record retains up to 32 distinct rejected
  token SHA-256 digests so late failures cannot reopen a newer rejected credential. Version 1 single-digest records
  migrate without losing evidence. A 33rd rejection durably fails closed with unavailable recovery state. Changing
  credentials or disabling recovery mode cannot clear exhaustion; a maintenance reset requires separate review.
- The JSON payload is bounded to 4 KiB within an 8 KiB persistence envelope. Corrupt, oversized, unsupported,
  inconsistent, unreadable, or contended state never becomes an implicitly disabled recovery gate.
- Provider deadlines handle numeric and HTTP-date Retry-After, reject nonfinite input, and use the processor's
  immutable configuration. The standard configuration clamps to 60 seconds through 24 hours with a 10-minute
  malformed/missing fallback. Already admitted responses cannot shorten a later
  shared deadline. Processor cache checkpoints use that validated shared boundary too.
- Authentication stops and provider-admission stops explicitly mark partial traversal; an absent retry date never
  fabricates a completed collection run or replaces the previous completed-run evidence.
- Legacy query invalidation is limited to the matching folder query. An interrupted marker is committed before
  awaiting fresh reassessment; classified results persist and unrelated caches, existing posters, and locks survive.
- Recovery mode guards provider admission and every synchronous fresh/cached/restyle/replacement/removal boundary.
  The `PersistenceAccess` remains held through existing identity, ownership, suppression, and settings validation.
  Provider networking holds no persistence access. Releasing mode performs no processing or request by itself.

## Behavioral verification and review

Behavioral red/green regressions covered legacy obsolete dates/cache reuse, failure category preservation,
recovery-mode admission and icon-change access checks, out-of-order credential failures, capacity exhaustion, partial
authentication traversal, and nonfinite Retry-After through a real wrapped processor. Independent review findings
I1 (credential race), I2 (false completed traversal), and I3 (nonfinite processor deadline) are resolved with regression
tests and independent re-review PASS.

The Common suite passed 150 Swift Testing tests across 16 suites plus 44 XCTest tests. The application harness
passed 159 Swift Testing tests across 21 suites. These pre-final-layout runs are supplemented by the fresh final
coverage run below. The two existing opt-in process/scale probes remain separate from ordinary unit execution.

`rtk proxy bash scripts/test-recovery-process.sh` passed a disposable, separate-process probe: SIGKILL releases a held
mutation lock, saved recovery mode survives process recreation, an already constructed service cannot bypass a
subsequent mode change, and explicit disabling permits a later admission. This probe does not launch Finder or
itself prove absence of automatic replay; host/model tests cover that behavior. A separate processor regression
cancelled after one real temporary-folder icon checkpoint, recreated the processor, and verified only unfinished
work resumed without rewriting the completed icon.

Key logs: `/private/tmp/mfp-recovery-common-full-final.log`, `/private/tmp/mfp-recovery-application-full.log`,
`/private/tmp/mfp-recovery-process-probe.log`, `/private/tmp/mfp-recovery-auth-partial-{red,green}.log`, and
`/private/tmp/mfp-recovery-nonfinite-red.log`.

## Final validation — 2026-10-20

The final `scripts/test-coverage.sh` run passed with complete production-source accounting and no missing
executable files. Application: 159 Swift Testing tests across 21 suites. Common: 150 Swift Testing tests across
16 suites plus 44 XCTest tests. FileSystem: 62; Log: 13; Network: 21; Persistence: 13. The two pre-existing
opt-in Common probes remain skipped in this run; the dedicated recovery process probe ran separately and passed.

| Component | Covered/executable lines | Coverage |
| --- | --- | --- |
| Project — host plus Finder | 3615/3989 | 90.62% |
| Host — reported separately | 3370/3656 | 92.18% |
| Finder — reported separately, fully counted above | 245/333 | 73.57% |
| Network | 323/351 | 92.02% |
| FileSystem | 1168/1289 | 90.61% |
| Persistence | 331/361 | 91.69% |
| Log | 138/140 | 98.57% |
| MovieFolderCommon | 2545/2807 | 90.67% |

- Final SwiftLint: zero findings, unchanged `.swiftlint.yml`, no new exclusions or suppressions.
- Signed native Debug `build-for-testing` and Release build: PASS. Both app bundles passed
  `codesign --verify --deep --strict` with access to macOS trust services. Signing was not disabled.
- Source style review preserves the guide's contextual `nil` exceptions and public concurrency contracts.
  Short synchronous provider-test witnesses satisfy the unchanged async protocol; no unsafe isolation suppression
  was introduced. Whitespace and width checks cover all 139 Swift files, including new untracked sources.
- Independent review: PASS, including re-review of I1–I3. No open Critical/Important findings remain.
- Final `git diff --check`: PASS. Style commit: `58e6d33`; recovery feature commit: `008a6f3`.
  The verified feature was integrated into local `develop` with `git merge --ff-only`.

Coverage artifacts:
`/private/var/folders/h0/423hyq0d1mj429_q6zhqkw9r0000gn/T/MovieFolderPosters-Coverage.jkFuCJ`.
Native build logs: `/private/tmp/mfp-recovery-native-debug.log` and `/private/tmp/mfp-recovery-native-release.log`.
Lint artifacts: `/private/tmp/mfp-recovery-lint-final.json` and `/private/tmp/mfp-recovery-lint-final.log`.

SwiftLint and the coverage gate belong to final validation or an explicit user request; routine implementation
edits do not trigger either check. No further run is needed merely because validation documentation changes.

## Local feature completion — 2026-10-20

The user explicitly approved committing recovery, finishing the feature, updating documentation, and committing
that documentation on `develop`. The feature commit is `008a6f3`. Local `develop` advanced from `fd9eb83` to that
commit with a fast-forward merge; no merge commit or history rewrite was created. This also integrates the
previously approved coordinator, coverage, lint, and style commits carried by the feature branch.

Before integration, the Common suite again passed 150 Swift Testing tests and 44 XCTest tests; the application
suite passed 159 tests across 21 suites. The merged source tree exactly matches the verified feature tree.
Integration test logs: `/private/tmp/mfp-recovery-integration-common.log` and
`/private/tmp/mfp-recovery-integration-application.log`. The merged application check is recorded in
`/private/tmp/mfp-recovery-merged-application.log`. No additional lint or coverage run was triggered by documentation.

The remote was not pushed, and GitHub issue #4 was not modified or closed. Issue #5 remains separately scoped.
The fully merged local branch `feature/processing-recovery` was deleted after explicit user approval.
User-specific `.DS_Store` and Xcode `xcuserdata` files remain untracked and were excluded from both commits.
