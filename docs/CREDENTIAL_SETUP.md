# Credential setup and replacement — R100-06

Status: R100-06 was implemented and independently reviewed on `feature/credential-setup`,
validated, and fast-forwarded to `develop` on 2026-10-22. Implementation and validation
commits are `c5f8024` and `2d02b56`. The live credential and installed Finder qualification
limits below remain. No live credential entry was performed by the agent.

## Approved requirements

- Use `TMDbClient.validateCredential()` against `/3/authentication`, requiring HTTP 200
  and JSON `success: true`. Keep bearer authorization out of URLs and error content.
- Explain the API Read Access Token in Settings, link to TMDb API settings, and expose
  explicit saved-token testing with safe distinct outcomes, progress and cancellation.
- Test candidate credentials before saving/replacing. Confirm replacement and removal;
  capture the expected generation before confirmation and reject stale operations.
- Read configuration and Keychain under one short settings lease. Never hold a lease
  across network work. Recheck generation after saved-token testing and at candidate commit.
- Preserve revision-before-Keychain ordering. A failed Keychain mutation may advance
  the revision; report failure and reload, never claim success or roll back newer state.
- Represent absent persisted configuration explicitly for first-run conditional updates.
- Keep diagnostics usable in recovery mode while respecting shared provider backoff.
  Candidate authentication errors do not fill the processing rejected-token ledger.
  Diagnostics do not clear processing restrictions. Record other provider failures safely.
- Preserve accessible explicit selections and manual-required decisions across credential
  replacement/removal. Version-2 settings separate `processingCacheRevision` from
  `credentialRevision`; version-1 migration anchors the existing namespace. Unknown or
  malformed schemas fail closed. Fixture-mode changes rotate both generations.
- Stamp operational caches with the captured credential revision. Reconcile centrally:
  clear cached searches and authentication-specific failure/retry evidence on changes;
  retain decision identity, fingerprints, selections, manual/parsing/missing-artwork states,
  valid provider throttling, existing coordination, and all icon-change policy checks.
- Show a local parser preview in Settings and the actual normalized title/year in Choose
  Movie. Preview and search share normalization; previews make no network requests and
  persist neither input nor credentials. No parser grammar change is included.
- Preserve Swift 6, programmatic AppKit, existing modules, roots, bookmarks, movie contents,
  posters, and ownership/suppression policies. No new process, watcher, or dependency.

## Implementation tasks and ownership

| Task | Owner | Files / responsibility | Interfaces |
| --- | --- | --- | --- |
| Network validation | Network worker | `Packages/Network` source and tests | `TMDbClient.validateCredential() async throws` |
| Shared state and preservation | Storage worker | Common configuration/recovery/cache source and tests; Finder and poster-action service composition | `CredentialState`; revision-checked configuration API; diagnostic recovery API; processor credential stamp |
| Host credential flow and previews | Root | DirectoryConfigurationService, ConfigurationViewModel, Settings/coordinator, poster-action model/view; host tests | Consumes Network and Common interfaces below |
| Independent review | Reviewer | Entire approved diff, with owners retained for fixes | Explicit PASS after blocking findings resolved |

Common interfaces consumed by the host:

```swift
struct CredentialState: Equatable, Sendable {
  let isConfigured: Bool
  let revision: UUID?
}
// ConfigurationServicing additions/replacements:
func credentialState() async throws -> CredentialState
func testCredential(expectedRevision: UUID?) async throws
func saveCredential(_ value: String, expectedRevision: UUID?) async throws
func removeCredential(expectedRevision: UUID?) async throws
// ConfigurationRepository:
func readIfPresentHoldingAccess() throws -> (DirectoryConfiguration?, PersistenceAccess)
func updateCredential(expectedRevision: UUID?, afterCommit: () throws -> Void) throws
// ProcessingRecoveryService:
func validateCredentialTestAllowed() throws
func recordCredentialTestFailure(_ error: any Error) throws
// MovieFolderProcessor initializer:
// credentialRevision: UUID? = .none
```

### Progress and evidence

- [x] Inspect current implementation and live issue #6; combined code/design proposal approved.
- [x] Network baseline: 21 tests passed. Sandbox-compatible caches are under `/tmp/mfp-r100-06-*`.
- [x] Network test-first implementation and focused package check.
- [x] Shared schema/cache/recovery test-first implementation and focused package checks.
- [x] Host service and UI implementation with focused host-harness tests.
- [x] Independent review and fixes; final PASS with no open findings.
- [x] Implementation approved and committed as `c5f8024`.
- [x] Formal validation approved; validation changes committed as `2d02b56`.
- [x] Feature completion authorized; commits fast-forwarded to `develop` and this delivery record updated.

## Review focus

First-run absence; saved-token changes during a request; stale confirmation; cancellation
before commit versus completed commit; Keychain failure after revision advancement;
version-1 migration and unknown schema rejection; usable explicit matches after repeated
changes/removal; late old-generation failures; live/fixture isolation; preview/search parity;
redaction and no remote work merely from viewing Settings or previews.

## Coordination check

Network produces the method consumed by the host; storage produces the exact Common
interfaces above. Storage owns composition changes in Finder and MoviePosterActionService;
Root owns poster presentation. Only Root edits this document. No concurrent test runs that
share a package build directory. All implementation owners preserve other actors' edits.
Repository approval gates supersede skill defaults about automatic commits, integration,
plan-review handoffs, and replacing worker/reviewer owners after fixed round counts.

## Implemented behavior and migration

Network accepts only HTTP 200 with an `application/json` response explicitly reporting
`success: true`. Settings provides guidance/help navigation, Test Saved Token, confirmed
test-before-replacement/removal and cancellation. Candidate text stays in NSSecureTextField
until submitted and is then held only by its finite operation; view-model state contains
presence, generation and fixed messages. Test results are revalidated after both successful
and failed requests. Delayed notifications preserve mutation feedback only while its
reloaded generation remains current. Stale presence reads cannot overwrite a newer read.

Credential diagnostics always use the injected live-style HTTP transport, independently of
Debug movie fixtures. Recovery initialization remains optional for configuration availability;
missing recovery storage blocks credential networking. Diagnostics respect shared backoff but
do not reset processing recovery mode or rejected-credential restrictions.

Version-1 decoding anchors `processingCacheRevision` to the existing credential revision.
Version-2 writes preserve that namespace across save/removal and require the explicit cache
revision on decode. Fixture transitions rotate both revisions; repeated selection of the
same fixture setting does not rotate either. Central cache reconciliation retains saved
movie identity, explicit selections and manual-required outcomes, clearing queries and
authentication-specific evidence. Source poster caches and shared throttling remain intact.
The old settings record key is retained to maintain the same cross-process lease and ensure
older binaries encounter the unsupported version and fail closed.

Settings preview uses the production parser without scanning a collection. Choose Movie
uses `MovieMatchingRequest` for both its local disclosure and actual title/year
arguments, preserving the existing 1888–2099 input range.

## Focused implementation evidence — 2026-10-22

These are implementation checks, not completion of the separately authorized Validation Phase.

- Network: 30 Swift Testing tests passed (`/tmp/mfp-r100-06-network-final.log`).
- Common: 40 Swift Testing tests plus 14 XCTest poster-action tests passed
  (`/tmp/mfp-r100-06-common-focused.log`). Includes actual saved-movie lookup across
  three credential changes without searches or poster downloads.
- Host/Finder: 145 selected Swift Testing tests in 16 suites passed
  (`/tmp/mfp-r100-06-host-focused-final.log`). These cover affected configuration,
  coordinator lifetime, action, summary and Finder integration paths in the library harness.
- Seven native pane presentation tests passed after final wrapping-width constraints; see
  `/tmp/mfp-r100-06-native-pane-final.log`.
- Initial interface-addition compilation failures were followed by integration fixes.
  Behavioral red/green regressions reproduced late old-token failure attribution and
  delayed-notification loss of mutation feedback before their fixes. Expanded checks also
  identified old status wording and subscriber-count expectations; related tests now assert
  current status propagation and subscriber delivery rather than a fixed publish count.
- Coherent summary reads retain the prior eight-attempt/20 ms contention retry, with no
  lease held during waits. Its new short-contention regression failed before restoration
  and passed in the final 145-test host run.
- Existing compiler warnings about unused recorder results and weak-variable mutability in
  older test fixtures remain. SwiftLint, full style validation, coverage and signed builds
  have not been run in this Implementation Phase.
- `git diff --check` passed. No commit, merge, push, issue update or extension registration.

The independent reviewer identified I1 (late failure after credential replacement), I2
(recovery-store initialization preventing configuration), and N1 (late notification erasing
mutation feedback). Root fixed these after the service/storage owners became unavailable
due tool usage/thread limits; the same reviewer retained review ownership. No approved
architecture or product scope was changed to resolve them.
The final independent review returned PASS after the contention-retry restoration, with
no open findings. Implementation commit approval and authorization to start formal
validation are still pending.

## Qualification limits

Live TMDb authentication, native credential entry, signed installed-host behavior and Finder
behavior after credential replacement require separate native evidence. Automated transport,
Keychain-backend and host-harness tests do not establish those observations.

## Approved environment API follow-up — 2026-10-22

The public `MovieFolderEnvironment.EnvironmentKey` enum is the closed list of supported
environment values. Each case's `String` raw value is the configured value; callers retrieve
it through `MovieFolderEnvironment.env(_:)`. Its `value` accessor remains internal, and static
environment functions use the accessor with explicit type qualification. Host and Finder
Keychain composition use `env(.groupIdentifier)`. This design keeps configuration immutable
without mutable static state or an actor singleton.

The three shared notifications now belong to `Notification.Name+MovieFolder.swift`, with
application-specific member names and exactly preserved raw strings. Production notification
senders, observers and Keychain consumers were migrated together. `AGENTS.md` records both the
notification declaration convention and environment-key API rule. This source refactor does not
change entitlements or register an extension.

Focused Common environment/revision checks passed (10 tests; see
`/tmp/mfp-r100-06-environment-common.log`). The host/Finder check passed 145 tests in 16 suites
(`/tmp/mfp-r100-06-environment-host.log`). Independent follow-up review returned PASS with no
open findings; `git diff --check` passed. These were implementation-phase checks; formal
validation results are recorded below.

## Formal validation — 2026-10-22

- Requirement verification: reviewed the approved credential, generation-fencing, cache
  preservation, configuration API, and notification changes against their implementation
  and focused behavioral tests. No requirement mismatch was found.
- Unit tests: MovieFolderCommon passed 182 tests across 18 suites; Network passed 30 tests.
  The host harness passed 61 selected tests across six credential/configuration suites,
  including cancellation, stale reads, replacement/removal, help actions, previews, and
  safe error presentation. The host harness compiled its broader targets; compiler warnings
  came from existing unrelated Finder/installation tests. No test failed.
- SwiftLint 0.65.1: ran with `.swiftlint.yml` on all 12 Swift files modified during
  validation. It reported three `async_without_await` warnings: the test transport's async
  protocol witness (`CredentialServiceTests.swift:303`) and two async service protocol
  witnesses (`DirectoryConfigurationService.swift:325,369`). These signatures satisfy
  async protocol contracts; no other lint findings appeared.
- Swift style guide: reviewed the modified Swift files for the repository's 120-character
  limit, naming, access control, declaration organization, and Swift 6 concurrency conventions.
  No style deviations requiring changes were found.
- Validation support: the coverage-report helper's immutable notification declaration
  classification was regression-tested (15 tests passed); `git diff --check` passed.
- Coverage limitation: the last broad coverage snapshot before final focused additions reported
  89.55% aggregate coverage, below the repository's >90% gate. A fresh project-wide coverage
  run was not performed in this validation scope; therefore aggregate coverage remains
  unverified for the final diff. No signed build, live TMDb credential entry, or installed
  Finder qualification was performed.
- No blocking test failures remained at approval. The lint warnings above are contract-required,
  and the coverage/native qualification limits are reported explicitly.
