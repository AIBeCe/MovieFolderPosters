# R120-03 — Bounded search pagination implementation plan

> Agent workflow: apply superpowers:subagent-driven-development or executing-plans, with the repository's
> approval and Git gates taking precedence. No commit is authorized by proposal approval alone.

**Goal:** Search additional TMDb pages within a user-configured finite budget without weakening identity safety.

**Architecture:** Network supplies validated individual pages. MovieFolderCommon aggregates them sequentially
through the recovery-aware provider. Shared configuration captures the global budget; the existing AppKit
Settings and Choose Movie interfaces expose the choice and incomplete results.

**Tech stack:** Swift 6, Swift Testing, programmatic AppKit, existing local SPM services; no new dependencies.

**Specification:** GitHub issue #17 and the four proposals approved in this chat on 2026-10-31. The decisions
below are the durable specification. The initial fixed three-page proposal was superseded by the approved
global setting (default 3, range 1–5). Implementation is authorized; formal Validation, Acceptance Testing,
committing, merging, and pushing are not authorized.

## Global constraints and approved design

- Finder remains the browser; preserve movie contents, real settings, credentials, and icons during checks.
- Use the existing checkout on `feature/bounded-search-pagination`; preserve unrelated untracked user data.
- Network: `MovieSearchPage` contains `movies`, `page`, and `totalPages` and a public initializer.
  `TMDbClient.searchMoviePage(title:year:language:page:)` requests exactly one positive page and validates its
  metadata and movies. No automatic HTTP retries or hidden multi-page requests.
- Common: replace the provider search requirement with the page API. Provide whole-search
  `searchMovies(title:year:language:pageLimit:)` as a protocol extension. All production paths must supply their
  captured limit; no accidental first-page-only path or default limit bypass.
- Aggregate sequentially, at most `pageLimit` requests; stop once complete. Validate requested page and consistent
  total pages. Permit provider total zero only for an empty first page. Identical movie records deduplicate in
  first-seen order; conflicting records for one ID throw `TMDbError.malformedResponse`.
- Check cancellation before/after pages and before returning. Any page failure throws; do not publish or cache
  the preceding partial pages as a successful search. Recheck durable shared admission before every page.
- Preserve existing completeness refusal, five-ID evidence ceiling, and conservative title/year rules.
  Identification request ceiling: `pageLimit + 5 aliases + 5 release-date requests`, maximum 15; artwork excluded.
- `DirectoryConfiguration.searchPageLimit` is global, default 3, valid integers 1–5, independent of collection
  matching overrides. Capture it when starting a search. Existing configuration cancellation/stale-result
  safeguards remain active; no budget expansion during an in-flight search.
- Cache search keys include captured limit; alias keys preserve their existing encoded representation.
  Keep cached movies/hasMorePages representation; do not reopen confirmed identities solely for a budget change.
- Settings schema 6→7 uses the existing explicit backup-protected migration. Older supported versions convert
  through the existing chain, then acquire limit 3. Current-schema missing/invalid fields fail closed. Preserve
  authorization, credential/cache/history generations, bookmarks, overrides, and saved decisions.
- AppKit: native popup 1–5 in a Search requests group below Matching Defaults controls; global-scope help,
  accessible label/help, busy disabling, failure restoration, semantic colors, wrapping text, existing window.
- Choose Movie incomplete suffix: “Search page limit reached. Results are incomplete. Refine the title or year,
  or increase Maximum search pages in Settings.” Persist it through candidate selection; no preselection.
- Saved incomplete-search explanation: “Search results are incomplete, so a unique movie could not be
  established. Refine the search or review Maximum search pages in Settings.” Preserve typed provider errors.
- Apply the installed Swift Style Guide to edited Swift and Swift Testing guidance to tests. Do not run lint
  during implementation; reserve formal four-part validation and XCUITest acceptance for separate approval.

## Review focus

- Cross-process backoff or recovery-mode changes between pages prevent the next request.
- Cancellation drains deterministic fixture requests and cannot publish stale search or mutate real icons.
- A late competitor/conflicting duplicate cannot be hidden by early uniqueness or first-record preference.
- Cache keys, captured configuration, and collection overrides cannot bypass the global budget.
- Schema migration preserves useful data and generations and does not weaken strict current-schema decoding.

## Task 1 — Implement approved Points 1–4 as one integrated change

Ownership: implementation worker owns production/test sources and scripts only when directly necessary;
Root owns this plan and other Markdown documentation. One coherent worker owns the cross-layer API lifecycle.

### Point 1: Individual provider pages

Files: Network `Network.swift`, `TMDbClient.swift` (a focused search extension is allowed), Network tests.

- [x] Add failing page-contract/request/metadata tests and record RED evidence (distinguish API compile RED
      from behavioral RED).
- [x] Add `MovieSearchPage` and single-page API; retain compatibility only where it cannot hide pagination or
      shadow Common aggregation. Validate positive requested pages and returned page/totals, including zero.
- [x] Run focused Network tests with writable SwiftPM caches; log exact results.

### Point 2: Common aggregation, recovery, cache, and integration

Files: Common processing contracts, new `MovieMetadataProvider+Search.swift`, recovery wrapper, metadata cache,
processor configuration/creation/automatic/manual paths, host PosterActions provider and search calls,
directly affected production and test conformances.

- [x] Add deterministic bounded-search tests: completion 1/2/3/5, exhaustion 1/3/5 with 6 total, duplicate records,
      malformed metadata, invalid limits, late ambiguity, cancellation, and per-page shared recovery.
- [x] Implement the approved aggregation; adapt test providers explicitly rather than inventing a permissive
      fallback for missing pages.
- [x] Propagate the captured limit through every production caller and search key; retain alias-key compatibility.
- [x] Exercise processor/persistence integration and existing directly affected recovery/evidence-budget tests.

### Point 3: Global configuration, explicit migration, and native presentation

Files: Common configuration/repository/summary/service protocols/migration; host configuration service/view model,
SettingsViewController, PosterActions presentation, activity/result explanation, directly affected tests.

- [x] Add default/range/round-trip/migration/failure-restoration tests; see TDD evidence limitation below.
- [x] Implement schema 7 and explicit prior-schema conversion with default 3 and preservation assertions.
- [x] Add `setSearchPageLimit`, summary/model propagation, and existing notification/cancellation integration.
- [x] Implement the approved native popup and incomplete messages, preserving existing AppKit hierarchy.
- [x] Compile host/Finder integration using existing isolated scripts without app launch, registration, credentials,
      or icon writes. Visual checks only if an already safe, authorized fixture path is available; otherwise report
      unperformed. Do not change signing or entitlements.

### Point 4: Focused regression checks and handoff

- [x] Run issue-relevant Network, Common processing/recovery/configuration/migration and host presentation tests.
      Include existing affected tests; no unrelated full-project run, lint, or formal acceptance run.
- [x] Record tests, failures/skips/blockers, raw log paths, and any ordinary corrections to this plan via Root.
- [x] Obtain independent spec/correctness review; resolve Important/Critical findings with the same worker/reviewer.
- [x] Present implementation for user review. Do not commit, start formal Validation/Acceptance, or finish feature.

## Implementation status and focused evidence

Implementation is complete on `feature/bounded-search-pagination`, uncommitted and ready for user review.
Independent implementation review: **PASS**, with no remaining Critical/Important findings. This is not formal
Validation or Acceptance approval. No commit, merge, push, lint, app launch, extension registration, live TMDb,
real settings/credentials, or real movie-folder icon operations were performed.

Baseline: `168fded` on develop; tracked tree initially clean. Unrelated Xcode user data and parser SwiftPM state
remain preserved. Existing checkout reused; no new worktree requested. Interface preflight matched the single-page
contract, captured global pageLimit, strict schema 7, and the unchanged five-ID evidence ceiling.

| Focused check | Result | Evidence |
| --- | --- | --- |
| Network page API and package regressions | PASS — 59 tests, 1 suite | `/private/tmp/r12003-network-final.log` |
| Common edited-source processing/recovery/configuration/migration selection | PASS — 164 tests, 11 suites | `/private/tmp/r12003-common-final-green.log` |
| Additional repository/migration preservation checks | PASS — 2 tests; overlaps the preceding selection | `/private/tmp/r12003-migration-extra.log` |
| Initial host/Finder all-source compile and host regressions | PASS — 52 tests, 6 suites | `/private/tmp/r12003-host-final.log` |
| Final passive-reload scheduler regressions | PASS — 19 tests, 1 suite | `/private/tmp/r12003-i1-scheduler-final.log` |
| Final isolated host/Finder all-source compile and notification/configuration regressions | PASS — 25 tests, 5 suites | `/private/tmp/r12003-i1-host-final.log` |
| Whitespace integrity | PASS | `git diff --check` |

Selections overlap and must not be summed as unique coverage. Earlier broader issue-relevant Common execution
passed 179 tests in 11 suites (`/private/tmp/r12003-common-regression-serial.log`). Deterministic temporary stores,
controlled HTTP/provider fixtures and recording assignment adapters protected live user data. The host/Finder
harness compiled disposable copies of actual sources without launching executables or running Xcode registration.

### Review findings and approved correction

- **I1 — resolved.** Initial review found the generic configuration notification requeued observed roots, allowing
  eligible searches immediately after a page-limit save. The user approved the focused passive correction in
  `/private/tmp/R120-03-I1-proposed.diff`. Only page-limit changes send `scheduleObservedCollections: false`; other
  configuration changes retain the default true behavior. Passive reload cancels/drains active work and reloads
  settings without synthesizing visits, preserves genuine queued/event/retry triggers and timer generation, and
  prunes resources for removed roots. Normal resume requests stay sticky across concurrent/coalesced reloads.
- **I2 — resolved.** The first negative scheduler assertions relied on a short absence delay. They now require an
  explicitly observed sentinel root to be the next started visit and verify the complete processed sequence.
  An unwanted replacement would precede the sentinel. No new production testing hooks were introduced.
- The exact notification parser was extracted into an internal static Finder method for isolated tests without
  constructing a live extension. It is a pure value operation independent of instance state. Root approved this
  directly necessary, behavior-preserving testability extraction.
- Same-URL monitor assessment: an unauthorized physical replacement fails expected identity and is pruned.
  A reauthorized replacement is an ordinary configuration change whose true notification refreshes monitors,
  including when coalesced with a passive request. The existing reliance on delivery of those separate hints
  remains; no speculative monitor architecture expansion was made.

Independent review report: `/private/tmp/R120-03-review-report.md`. Full worker handoff and changed-file list:
`/private/tmp/R120-03-implementation-report.md`. Same worker/reviewer retained ownership through fixes and PASS.

### RED evidence, intermediate failures, and corrections

- Initial page API tests recorded missing-symbol compile RED (`/private/tmp/r12003-network-red.log`). A
  preimplementation behavioral RED was not established for every initial aggregation/configuration addition;
  do not claim complete behavioral TDD evidence for those additions.
- I1 has genuine executed behavioral RED: with only the parameter surface added and original scheduling retained,
  `passiveReloadDoesNotScheduleIdleObservedRoot` and `passiveReloadDrainsActiveWorkWithoutReplacement` each
  observed the extra visit (2 failures, `/private/tmp/r12003-i1-behavior-red.log`). Missing-API compile RED is
  separate (`/private/tmp/r12003-i1-api-red.log`). Final corrected tests passed as recorded above.
- Default cache permission failures were resolved with writable temporary caches and `--disable-sandbox`.
  Some manifest cache warnings remained; completed commands succeeded. No credential or entitlement changes.
- An earlier parallel Common run stalled and was interrupted; serial issue-relevant execution passed. It is not
  reported as a passing run. Test-call/enum mistakes and async fixture calls were corrected before final checks.
- The first extra cache test advanced its clock beyond query TTL; fixture timing was corrected to keep the old
  cache entry unexpired while retaining the stronger cache-separation assertion. An existing malformed-current
  settings fixture's envelope changed from schema 6 to 7 to retain its original purpose. Intermediate logs are
  preserved in the full handoff report; no production assertions were weakened.
- Root spot checks restored the approved invalid-limit error type and ensured a conflicting historical
  `searchPageLimit` field is rejected rather than silently overwritten during migration.

### Remaining phase gates and limits

No rendered AppKit inspection, Light/Dark check, XCUITest acceptance run, Finder runtime/icon persistence,
live-user-data migration qualification, signing/notarization, or full project suite was performed. The installed
Swift Style Guide was applied during implementation/review; formal four-part Validation (including SwiftLint)
requires separate authorization. Acceptance requires its own scenario discovery, preflight, approved executable
coverage, and actual execution. Implementation approval is required before committing these changes. Nothing
in these focused results authorizes formal Validation, Acceptance, feature completion, merge, or push.
