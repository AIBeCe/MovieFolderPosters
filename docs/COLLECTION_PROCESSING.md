# Authoritative collection processing results — R100-02

R110-03 adds presentation-only state/reason filtering to Unresolved Results. The combined implementation is in
progress; see [Result filtering and private history](PRIVATE_HISTORY.md) for the approved contracts and evidence.
Filters do not create outcomes, authorize actions, or start processing. Required saved processing evidence remains
available for private collections.

Status: Implemented, independently reviewed, verified, integrated into `develop`, and pushed to GitHub.
Implementation commit: `049b74b`. Local integration uses `git merge --ff-only`.
The user approved the complete proposal on 2026-10-17, with `FolderProcessingState` as the enum name.
The user authorized a local commit on 2026-10-18, superseding the earlier no-commit boundary.
Issue #2 was closed as completed on 2026-10-18. The merged feature branch was deleted.
`develop` was pushed to GitHub through `b48d44d` on 2026-10-18. No release was published.

## Scope and decisions

Keep movie-specific result models and the repository in Shared/Processing/Collections. Reuse the existing
Network, FileSystem, and Persistence services. Existing query/decision caches are not collection summaries.
Persist per-collection UUID snapshots separately from activity events. No database, new module, watcher,
polling, daemon, additional process, or scheduled execution is authorized.

Each visible immediate child directory has one assessed processing state: pending, done, notFound,
severalMatches, unresolved, preserved, suppressed, failed, deferred, or uncertain. Only verified owned
posters with a valid saved movie identity count as Done. Complete searches with no suitable identity count
as Not found; ambiguity counts as Several matches. Incomplete searches, missing artwork, parsing problems,
preservation, suppression, failures, and deferral remain explainable outside those headline counts.
A failed refresh does not erase a still-verified installed poster. Supporting identity, ownership, retry,
latest-attempt and timestamp facts are separate from the exclusive current state.

Total belongs to a timestamped inventory of visible immediate child directories, excluding hidden entries,
files, symlinks, and descendants. Known directories with inspection failures remain members. Unclassifiable
entries make inventory incomplete and Total unavailable. Unknown values never become fabricated zeros.

Snapshots carry schema/revision, collection/root/authorization identity, credential revision, fixture mode,
poster appearance, operation UUID/kind/times/state, membership and per-folder assessments. Retain current
snapshot/current operation and last completed collection-run metadata, not unlimited history. Legacy caches
cannot establish authoritative results without a current inspection.

## Consistency, interruption, and capacity

Writers retain existing root coordination. Commit lock order is coordination → current configuration →
short snapshot lease. Every commit checks current membership and processing context plus expected operation
ID/revision; no snapshot lease spans network work. Removed-root writers cannot recreate pruned records.
Readers never infer activity from contention alone. Orphan checks acquire coordination and reread snapshot.

Persist operation start before mutation. Complete inventory starts pending; checkpoint every 32 assessments
and at termination. Manual actions mark the affected folder pending before mutation. Uncheckpointed work
remains uncertain after interruption. Cancellation is not a negative matching result. Backoff ending a
traversal is partial. A manual completion is not a completed collection run.

Approved capacity: 10,000 directories, 8 MiB encoded Persistence envelope, batches of 32. Capacity
or result-storage failure prevents subsequent mutations during that attempt. Measure actual cost before
claiming these are qualified performance limits. Persistence enforces size limits before allocation and
replacement. Cleanup removes record data while preserving reusable lock files. Prune only the dedicated
Outcomes namespace under current configuration, on removal and normal startup; busy cleanup waits for a
later normal invocation. Preserve corrupt/unsupported active records and present unavailable.

Atomic record visibility and process-interruption handling do not establish power-loss durability.
Cache persistence failure and actual icon results must be reported independently.

## Presentation

Preserve Main/Settings/Log and existing columns. Read committed results without triggering processing.
Total can be known while outcome counts remain unavailable. Label pending, partial, interrupted, stale,
and last-inspected evidence separately from root access. Add a read-only details sheet for states, reasons,
movie identity, ownership, last attempt, earliest retry eligibility, and last completed collection run.
Retry/correction controls belong to R100-05. Notifications only invalidate result views; no settings reload
or polling. Reload on open/activation and explicit refresh. Notifications are not authoritative data.

## Approved recovery policy — R100-04 and R100-05

Approved 2026-10-18. Issue #4 recovery behavior is implemented locally as of 2026-10-20, including reason-based
eligibility, shared provider policy, legacy reassessment, interruption recovery, recovery mode, and separate work
labels. See [Processing recovery](PROCESSING_RECOVERY.md) for contracts, tests, review, verification, and the explicit
local completion in commit `008a6f3`, fast-forwarded into `develop`. The issue #5 interface remains separately scoped. This policy
supersedes automatic cooldown-based repetition of confirmed manual-resolution results. The R100-02 records below
remain historical evidence.

### Folder state and next action

| Assessed condition | Automatic behavior | User action |
| --- | --- | --- |
| Not processed | Process on a later authorized invocation | No manual resolution required |
| Done with verified installed evidence | Preserve completed work | Explicit existing poster actions remain available |
| Not found from a complete search | Do not search again automatically | Manual search in R100-05 |
| Several matches | Do not search or select again automatically | Explicit movie selection in R100-05 |
| Temporary failure | Retry only when the recorded reason permits it and its delay has elapsed | Explain the failure and earliest eligibility |
| Interrupted or uncertain work | Resume eligible unfinished work after revalidating access, identity, and current evidence | Explain remaining work |
| Legacy unresolved record without a reason | Needs reassessment; perform one fresh classification on a later authorized invocation | Show the unknown assessment explicitly |
| Preserved, suppressed, or blocked by authorization/policy | Preserve the applicable safety restriction | Required explicit action or reauthorization |

These are behavioral and display concepts, not an approved replacement enum or serialized schema.
Existing states such as failed, deferred, and unresolved require their supporting reason to determine the
next action. Missing artwork, parsing problems, incomplete searches, authentication, throttling, and
connectivity must not be collapsed into an interchangeable retry state. The implemented mapping and recovery
conditions are recorded in [Processing recovery](PROCESSING_RECOVERY.md). Missing evidence never becomes a
fabricated Not found or Several matches decision.

### Eligibility, timing, and invocation

Persisted state and failure reason establish automatic retry eligibility. retryAt only establishes the
earliest time already-eligible work may run; its presence or expiry does not authorize a retry. Confirmed
Not found and Several matches stay in manual resolution for the same unchanged folder across visits,
cooldown expiry, configuration reloads, and process restarts. A replaced folder must be revalidated as a
different identity rather than inheriting an old assessment blindly.

An eligible retry or resume occurs on a later authorized invocation, including a Finder visit. While Finder keeps a
configured collection root under observation, a one-shot retry at the earliest eligible folder or provider deadline
may provide that invocation. Conclusive and admission-blocked outcomes do not arm this retry. A root-directory change
may also queue a coalesced visit. Both triggers stop with observation or extension
lifetime; there is no polling, daemon, persistent scheduler, or guarantee of execution at a displayed eligibility time.
Retry paths preserve shared provider backoff and existing authorization, identity, ownership, suppression,
cancellation, and recovery-mode safeguards.

### Legacy reassessment

Older operational cache records can contain unresolved status and a future retry date without a matching
reason. Those records cannot prove either manual resolution or a temporary failure. Display Needs
reassessment and bypass that obsolete retry gate and inconclusive cached decision for one fresh assessment.
Revalidate the folder and persist the resulting classification so later visits and restarts do not repeat
the legacy reassessment. An interrupted assessment remains resumable; a newly established temporary failure
follows its own eligibility policy rather than being treated as unclassified legacy data again.

Preserve verified completed work, installed posters, unrelated cache entries, reusable locks, configuration,
and activity. Do not clear whole stores or rewrite movie contents to force retries. The observed collection
with 33 processed and 301 reasonless unresolved records motivates regression coverage; those counts are a
diagnostic snapshot, not permanent application constants or a qualification of successful matching.

### Collection presentation

Show saved-state freshness separately from processing completion. Current means the saved assessment
matches its context; it cannot imply all folders are Done. Derive work labels and counts from folder evidence:

- Needs processing, including separately identified Needs reassessment records.
- Waiting to retry, with eligible deferred work and its earliest retry time.
- Needs manual resolution, including Not found and Several matches.
- Complete only when complete inventory and verified folder evidence establish no remaining processing,
  retry, manual-resolution, or unknown work. Preserved/suppressed folders remain explicitly accounted for
  and do not become fabricated Done counts.

Mixed conditions remain visible together; a manual-resolution count must not hide temporary failures,
and a retry count must not hide unprocessed folders. Preserve unknown inventory, stale context, running,
partial, interrupted, failed, and unavailable evidence rather than replacing them with a completion label.

### Delivery ownership and acceptance

[Issue #4](https://github.com/AIBeCe/MovieFolderPosters/issues/4) owns eligibility, safe resume, reasonless
legacy reassessment, collection status projection, and their tests. [Issue #5](https://github.com/AIBeCe/MovieFolderPosters/issues/5)
owns the manual search/selection interface and bounded user-requested retry. Opening that interface does
not initiate searches; the user must request them explicitly. Successful manual resolution updates saved
folder evidence and collection counts without reprocessing unrelated folders.

Point 1 behavioral verification passed in MovieFolderCommon tests for both complete empty searches and
ambiguous results, including a legacy future retry date, an absent retry date, a new folder, and a processor
restart. The authoritative snapshot records the expected state and reason with no retryAt after fresh
classification, legacy-date revisit, and restart. Independent review passed. The full MovieFolderCommon suite
passed 44 XCTest tests and 102 Swift Testing tests in 12 suites. Native Finder and manual-resolution UI
behavior are outside this point and remain unverified.

Recovery acceptance now has controlled regression coverage for:

- Configuration reload preserves confirmed Not found and Several matches as manual-resolution outcomes.
- Eligible temporary failures recover at the next authorized invocation, respect backoff, and preserve Done work.
- Interrupted processing resumes only unfinished eligible work after safety revalidation.
- Legacy records decode compatibly, bypass obsolete deferral once, persist classification, and resume safely
  after interruption without repeatedly classifying the same completed assessment.
- Collection labels distinguish freshness, manual work, retries, unknown assessment, and mixed conditions.
- User-requested search/selection/retry revalidates identity and authorization after asynchronous work;
  cancellation prevents subsequent unwanted writes without undoing already completed work.

The full remaining issue #4 implementation and subsequent local feature completion were explicitly authorized.
Recovery is committed as `008a6f3` and integrated into local `develop`; issue #5 was tracked separately below.

## R100-05 — manual resolution interface and selected retry

Implemented on `feature/manual-resolution`, validated, and integrated into `develop` on 2026-10-20.
The host projects saved unresolved-folder records in natural name order, presents searchable provider results,
supports explicit movie selection and retry of selected folders, and reports partial, stopped, and cancelled
work distinctly. Opening the results interface does not start a search. User-requested search, selection, retry,
and cancellation revalidate folder identity, authorization, suppression, and poster ownership after asynchronous
provider work and before mutation or cache updates. Successful resolution updates that folder's saved evidence
without rerunning unrelated folders.

Validation completed against the full issue scope:

- All six package/application coverage suites passed. Required package and Project coverage gates passed;
  total Project coverage was 90.06% (Host 91.33%, Finder 73.57%; Finder is reported but has no separate gate).
- Native Xcode Debug `build-for-testing` succeeded for the host, Finder extension, and test targets.
- SwiftLint reported zero violations across 148 files; the Swift style-guide review found no remaining issues.
- Independent review passed, including revalidation of safety state after search and artwork awaits.
- `git diff --check` passed. Validation fixes were committed as `a9b4970` and included in the fast-forward
  integration into `develop`.

Native Finder runtime behavior, live provider interaction, sandbox authorization prompts, and persisted icon
appearance on physical folders were not exercised by the automated validation run.

The 2026-10-22 follow-up bugfix is integrated into `develop` through `1b55de9`. A root-only filesystem event
monitor now revisits an observed collection after a direct child changes, and a one-shot continuation resumes
eligible deferred work at its recorded deadline while Finder still observes the root. Bracketed IMDb, TMDb,
TVDb, and Wikidata codes in supported suffix positions are parsed as annotations; they do not establish movie
identity. Older unresolved decisions with such suffixes receive one fresh classification. Processing Details and
Unresolved Results have explicit Close controls; Finder poster menu actions route through the extension's
principal object, and Done dismisses the nested Choose Movie sheet through its coordinator. The latest automated
validation passed all package and host/Finder harness tests, the 90% project coverage gate, SwiftLint, signed
Debug/Release builds, and strict signature verification. See
[observed collection validation](OBSERVED_COLLECTION_VALIDATION.md) for counts and
live Finder limits.

## Implementation ledger

- [x] 1. Shared state, reason, operation, snapshot, validation, and counting models with behavioral tests.
- [x] 2. Read-only complete inventory and strict ownership assessment with FileSystem tests.
- [x] 3. Bounded Persistence APIs and versioned snapshot repository with cross-process/revision/retention tests.
- [x] 4. Automatic processing, matching evidence, interruption, and Finder integration.
- [x] 5. Manual refresh/selection/removal integration with the same snapshots.
- [x] 6. Main counts/state, read-only details, notification invalidation, and presentation tests.
- [x] Final independent review, focused/regression verification, signed builds, and explicit native limits.
- [x] Issue #4 point 1: confirmed Not found and Several matches remain manual-resolution outcomes across visits,
  retry expiry, and processor restart. Implemented, verified, and independently reviewed; commit approved
  on 2026-10-18. The user subsequently authorized finishing the feature; it was fast-forwarded into
  local `develop` through recovery commit `008a6f3` on 2026-10-20.
- [x] Remaining issue #4 recovery implementation, independent review, and controlled recovery regressions.
  Final verification and local feature completion are recorded in [Processing recovery](PROCESSING_RECOVERY.md).
- [x] Issue #5 manual search, result presentation, explicit selection, selected-folder retry, and cancellation
  integration. Validated and fast-forwarded into `develop` on 2026-10-20; the 2026-10-22 follow-up bugfix is
  integrated as `1b55de9`. See the R100-05 record above.

## Implementation evidence

Naming correction approved on 2026-10-18: the persistence-facing application type is
`CollectionProcessingStore`, with matching source/test filenames and updated callers, harnesses, and Xcode
references. This is a naming-only change; serialized fields, storage keys, and existing data locations remain
compatible. `FolderProcessingState` continues to describe a folder's assessed condition.

The principal types in `Shared/Processing/Collections` own `FolderProcessingState` and typed failure evidence,
movie identity provenance, snapshot context, historical completed-run context, and presentation projection.
CollectionProcessingStore.swift owns short committed revisions, current-configuration fencing, post-commit
invalidation, and cleanup. A new authorization generation starts fresh evidence. A manual action in a new
processing generation cannot relabel untouched old assessments as current.

FileSystem inventory distinguishes unknown entry types from known directories whose icon inspection failed.
Strict poster inspection preserves I/O failures rather than converting them to unowned icons. Persistence
limits apply only when explicitly configured; legacy callers retain their original unlimited default. The
Outcomes factory explicitly supplies the 8 MiB envelope bound. Pruning never unlinks reusable lock files.

Automatic and manual results are independent of operational cache success. Tests inject a cache failure after
a real native assignment and verify that the installed poster remains Done, the storage failure is explained,
and no subsequent folder mutation occurs. Failed refresh/restyling similarly retains verified installed state.
Artwork failures retain established movie identity and remain distinct from metadata failures.

The host summary service executes reads/decoding outside the main actor, including under Xcode's approachable
concurrency settings. Orphan classification requires a successful coordinated reread; contention or unreadable
data never becomes proof of interruption. Outcome hints only reload results. Root-removal cleanup is asynchronous.
Details show readable evidence and provenance, not raw filesystem fingerprints, and label historical context.

## Verification record

Recorded 2026-10-18 from this implementation session, before commit and integration.
The implementation was subsequently committed as `049b74b`; see the delivery status above.

| Check | Result |
| --- | --- |
| Processing/manual harness | 43 existing XCTest tests and 9 Swift Testing integration tests passed |
| Outcome harness | 19 tests passed, including a separate-process snapshot reader during 40 parent commits |
| FileSystem package | 59 tests passed |
| Persistence package | 13 tests passed, including cross-process exclusion, size bounds, and safe pruning |
| Configuration harness | 32 tests passed |
| Configuration/AppKit UI harness | 29 tests passed, including off-main reads, orphan failures, and invalidation coalescing |
| Installation-readiness regression harness | 17 tests passed |
| Matching harness | 19 tests passed |
| Poster-action view-model harness | 8 tests passed |
| Signed Debug build-for-testing | Passed; host, Finder extension, and all test targets compiled |
| Signed Release build | Passed |
| Native Xcode unit target | Passed: 183 test cases, zero failures, two intentional skips; parameterized device report counts 235 successful executions |
| Strict deep bundle signature checks | Debug and Release passed with normal system trust-store access |
| Independent review | PASS; all blocking repository, service, processing, and UI findings resolved |
| Git whitespace verification | Passed |

Native test skips are `processReaderObservesOnlyCompleteCommittedStates` (requires the harness's standalone
probe) and `largeInventory32RecordCheckpointsReportEncodeAndEnvelopeCost` (explicit opt-in benchmark). Both ran
successfully in their dedicated harnesses; they are not unverified native passes. The test-only probe lives in
scripts/test-support, outside Xcode's synchronized test source group.

Final synthetic measurement: 10,000 records with 32-record checkpoints took 36.716 seconds, including 8.586
seconds of JSON encoding. Peak actual Persistence envelope was 1,971,809 bytes. This measures repository
serialization and local storage, not filesystem enumeration, provider requests, icon writes, or Finder latency.
The benchmark is opt-in: `rtk proxy env COLLECTION_PROCESSING_BENCHMARK=1 ./scripts/test-collection-processing.sh`.

Sandbox-only SwiftPM cache and signature-trust checks initially failed before their intended verification;
reruns with standard cache/trust access passed. Build warnings were existing weak-reference mutability
suggestions and App Intents metadata extraction without an AppIntents dependency.

Native results: /tmp/MovieFolderPosters-Outcomes/Logs/Test/Test-MovieFolderPosters-2026.10.17_20-32-18-+0200.xcresult.
This path is temporary evidence, not a required project dependency.

## Remaining qualification and stop boundary

No live TMDb credential/provider run, new Finder-process restart scenario, reboot durability, physical-volume
recovery, visual light/dark screenshots, or native VoiceOver speech check was performed for this feature.
Controlled AppKit/native icon tests and signed builds do not substitute for those observations. No XCUITest
UI automation was executed in the final native unit-target command.

The verified feature is committed, integrated into `develop`, and pushed to GitHub. GitHub issue #2 is closed as completed. R100-03 and later deliverables are not implemented or authorized.

## Approved naming cleanup — 2026-10-18

The user approved responsibility-based names across types, protocols, methods, properties, variables,
and constants. CollectionProcessingStore remains the persistence boundary; CollectionProcessingState
is the saved assessment, and CollectionProcessingSummary/Presentation/DisplayState describe host output.
FolderProcessingFailure records failure evidence; its reason and stage types describe that evidence rather
than an unspecified attempt. FolderProcessingState remains unchanged.

Model source files move into Shared/Processing/Collections and use their principal type names, mirrored
by tests. Store creation is makeCollectionProcessingStore; starting a saved operation is
recordProcessingStart; applying a selected movie's poster is applyMoviePoster. Installation metadata
inspection is readInstallationMetadata. No new ProcessingResult
type is introduced because the existing operation model includes active work as well as completed work.

This cleanup preserves serialized property keys, raw enum values, the existing App Group storage
namespace, record keys, and distributed notification string. Renamed source properties use explicit
CodingKeys. A pre-refactor JSON fixture was decoded and encoded with the original types before changes;
post-refactor decoding and byte comparison passed with identical encoded JSON. No migration, new
processing behavior, commit, integration, or push is authorized by this cleanup.

Naming-cleanup verification:

- Collection-processing harness: 20 tests passed, including legacy JSON and cross-process reads during commits.
- Processing harness: 44 XCTest and 9 Swift Testing tests passed.
- Final renamed model sources decoded the original fixture and produced byte-identical encoded JSON.
- Independent review of renamed declarations, callers, target membership, and compatibility: PASS.
- Signed Debug build-for-testing, signed Release build, and native unit-target execution passed.
- Installation-readiness harness after readInstallationMetadata rename: 17 tests passed; incremental review PASS.
- Final Debug build/native unit execution and Release build passed after that rename; strict deep signatures passed
  for both bundles. Native report: 185 passed cases, zero failures, two intentional skips (237 parameterized executions).
- Final native result: /tmp/MovieFolderPosters-Outcomes/Logs/Test/Test-MovieFolderPosters-2026.10.18_00-50-20-+0200.xcresult.

Prior feature verification above describes the pre-cleanup implementation. The final renamed implementation
was committed as `049b74b`. `develop` was pushed through `b48d44d` on 2026-10-18. GitHub issue #2 is closed as completed.

## Explicit processing-record schema upgrades — 2026-10-26 implementation

Current collection processing records use schema 2. The explicit **Migrate Saved Data…** command converts schema 1,
including historical matching keys in the current and last-completed contexts, after backing up original payloads.
Settings upgrade first to fence older writers. Normal processing never migrates a record implicitly. An old or
invalid result record produces per-collection recovery guidance while healthy collections/settings remain usable.
See [saved-data schema migration](STORAGE_SCHEMA_MIGRATION.md) for tests, interruption handling and limitations.
