# R110-05 Local Data and Support Exports — Implementation Plan

Status: implementation approved by the user on 2026-10-28 after refactor and dedicated-window review PASS.
Implementation commit authorized; formal Validation Phase remains unauthorized.
Baseline: `cc70db4`, branch `feature/local-data-support-exports`.
Issue: https://github.com/AIBeCe/MovieFolderPosters/issues/14

## Approved specification

Add a Local Data tab to existing Settings; retain Main/Settings/Log and programmatic AppKit.
The table shows category, estimated logical bytes, file count and completeness status, with capture times,
Refresh, category explanations and Prepare Support Export. Use native controls, semantic colors, keyboard
navigation and accessibility labels. Scroll content within the existing Settings dimensions.

Measure only known existing app locations: shared Posters, Processing (all revisions),
CollectionProcessingState/legacy Outcomes, Settings, Activity, NetworkHistory, ProcessingRecovery and
ProcessingLocks, MigrationBackups, and host-private Application Support MovieFolderPosters/Authorization.
Exclude movie files/icons, Keychain and extension-private authorization locations; explain exclusions.
No payload reads, decode, create, repair, prune, migrate or cleanup during measurement. Use descriptor-relative
traversal with no symlink following, no special files or mount crossing, cancellation, overflow handling and
finite traversal bounds. Missing is Not created, failed is Unavailable, incomplete is Partial. Logical sizes
are estimates over the measurement interval, not reclaimable/allocated bytes. Never label an incomplete total
complete. File counts are not semantic movie or decision counts. Avoid double-counting namespaces.

Use FileSystem for generic measurement, MovieFolderCommon for category ownership/reporting, host Features/LocalData
for presentation. Approved names: `LocalStorageCategoryUsage` (not LocalStorageMeasurement), `LocalStorageCategory`,
`LocalStorageReport`. Category enum cases: posters, processingCache, collectionResults, settings, activityHistory,
networkHistory, recoveryAndCoordination, migrationBackups, hostAuthorization. Report retains start/end timestamps.

Replace readiness export's immediate save route with a finite support sheet, also reachable from Local Data.
Default range is preceding 24 hours; Activity enabled, Network disabled; no entries selected. Date range and
source controls filter retained entries, selection is explicit, Select All Shown is deliberate; hidden selections
are removed. Preserve each source's commit order. Nonfinite dates are excluded; invalid ranges cannot preview.
Readiness and storage inclusion have explicit controls. Empty versus unavailable remains distinguishable.
No new recording/polling or persisted support session. Current history limits apply (500 per source). Private
history omissions cannot be reconstructed. Network lacks operation linkage; never fabricate correlation or
complete runs. Mutation receipts remain deferred to R140-01. Explain HTTP versus product success.

Save a bounded (2 MiB), versioned, pretty-printed UTF-8 JSON document after exact-content preview. Project only
allowlisted fields: capture times/interval; fixed readiness statuses; category estimates/counts/status/times;
Activity action/status/folderResult/reason/failure reason/stage and explicit numeric processing counters;
Network purpose/result. Never serialize original records/events or rich Activity text. No paths, names, movie
IDs, stored UUIDs, bookmarks, access grants, credentials, raw errors or request details. No identifying override.
Approved export entry name: `SupportExportActivityEntry` (not SupportActivityEvidence).

Freeze exact encoded bytes for preview/save. Any selection/inclusion/range changes invalidate preview. Recheck
selected retained identities and relevant privacy configuration before save; cleared/changed evidence or changed
privacy requires refreshed preview. New entries are never included silently. Oversized exports fail visibly,
without silent truncation. Native NSSavePanel saves locally; cancellation writes nothing; failures are sanitized.

ConfigurationCoordinator retains support flow coordinator for finite lifetime. Views forward through class-bound,
main-actor protocols with weak delegates; view models retain narrow Sendable services. Work runs away from main
actor; generation/cancellation fences prevent stale reads/preview and closed-sheet writes. Preserve existing
redaction behavior and readiness allowlist. No package additions, schema migration or unapproved unrelated edits.

## Implementation task and ownership

One worker owns the complete coherent approved issue across FileSystem, Common and host/test integration; one
independent reviewer retains review/fix ownership. Root owns architectural decisions, authorization and integration.
This single task avoids dispatching separate owners across dependent export/privacy/presentation contracts.

Expected file groups:
- New Packages/FileSystem/Sources/FileSystem/DirectoryStorageMeasurement.swift and matching tests.
- New Packages/MovieFolderCommon/Sources/MovieFolderCommon/LocalStorage/ and matching tests.
- New host Features/LocalData/ and Features/Support/ plus matching Features tests.
- Modify SettingsViewController, ConfigurationCoordinator, installation diagnostics projection as necessary.
- Modify application harness only if new sources require it; it currently copies all feature folders automatically.

### Task 1: Complete bounded implementation

- [x] Inspect exact collaborator APIs, target inclusion and current settings size before editing.
- [x] Write focused Swift Testing behavioral tests, capture RED evidence before production implementation.
- [x] Implement safe filesystem measurement and app category reporting; run relevant focused tests.
- [x] Implement support selection, allowlisted document, staleness/privacy checks and exact preview/save model;
      capture focused RED/GREEN tests for redaction, ordering, hidden selection, unavailable history and stale preview.
- [x] Implement Local Data pane and finite native support sheet; connect Settings/readiness routes and lifetimes.
- [x] Run new/changed and directly affected focused tests plus app/Finder Debug compilation as coherence checks.
- [x] Independent review, resolve Critical/Important findings with same worker/reviewer pair and focused checks.
- [x] Record concrete files, decisions, evidence and unperformed native checks below; return to user for approval.

No SwiftLint during implementation. Do not run the whole project suite. Apply swift-style-guide while editing.
Formal validation requires separate authorization and must later include verification, scoped tests, scoped lint
and scoped Swift style review. No commits, merge, push, extension registration, live provider requests or changes
to production app data/movie folders. Product documentation/tracker delivery updates follow authorized integration.

## Review focus

- Descriptor traversal cannot escape through swapped symlinks, special entries, hard links or mount points.
- Missing/corrupt/contended storage remains distinct; inspection must not initialize namespaces or decode grants.
- Export fields stay allowlisted even with malicious rich history and arbitrary readiness text.
- Clear, privacy changes, source/range edits and late async completions cannot restore stale preview/selection.
- Saved bytes equal displayed preview; cancellation, sheet closure and safe destination lifetime work coherently.

## Progress and implementation evidence

Worker: `/root/local_data_worker` (GPT-6.1 Sol, Medium). One owner is appropriate because the filesystem,
privacy, document and UI contracts need coordinated changes; no recursive delegation.

Preflight consistency check:

| Task/interface | Produces and consumes | Result |
| --- | --- | --- |
| Task 1 internal scope | FileSystem measurement → Common categories → host Local Data | Ownership agrees with existing package direction; no new dependency cycle |
| Task 1 support scope | retained services → allowlisted document → exact preview/save | Original rich events and paths remain outside encoded document; identifiers stay local |
| Task 1 tests/checks | focused Swift Testing and compilation → implementation review | No full-suite, SwiftLint, formal validation or commits; user phase boundary overrides skill defaults |
| Task 1 UI integration | Settings/readiness → retained finite support coordinator | Existing three-window model retained; no new permanent window |

Unrelated untracked DS_Store, Xcode user data and SwiftPM state preserved. Product documentation/tracker updates
remain deferred to authorized integration; this file records implementation state only.

Implementation checkpoint:
- FileSystem: 7 focused tests passed, `/private/tmp/R110-05-filesystem-green.log`.
- Common: 2 focused tests passed, `/private/tmp/R110-05-common-green.log`.
- Host: 21 focused tests passed, `/private/tmp/R110-05-host-focused.log` (complete-source temporary harness,
  batch compilation disabled). Latest tiny UI sizing/refactoring changes still need final confirmation.
- Unsigned Debug app/Finder build passed, `/private/tmp/R110-05-debug-build-final.log`, before final UI/file splits.
- Independent reviewer: `/root/local_data_reviewer`, review package `/private/tmp/R110-05-review.diff`.

Compiler investigation: baseline `cc70db4` compiles and passes 4 installation export Swift Testing tests
(`/private/tmp/R110-05-baseline-compile.log`). Current complete-source harness triggers Swift batch-compilation
diagnostics on unchanged `ActivityServiceFake`; fresh caches reproduce, an empty added Support test source is
sufficient, and disabling batch compilation permits compilation. No original test helper was modified/hidden.

One diagnostic invocation accidentally omitted its focused filter and ran 288 Swift Testing cases, reporting
9 issues; this was outside intended check scope, was stopped, and is not formal validation. Raw evidence:
`/private/tmp/R110-05-compile-diagnostic-nobatch.log`. Settings tab expectation is directly affected and has been
updated. Other observations concerned About icon sizes, prior results-sheet copy-button expectations and orphan
reread expectations; they remain outside this issue's implementation scope and were not suppressed or fixed.
No claim about their baseline status has been established by this investigation.

No formal validation, SwiftLint, app launch, explicit extension activation, live provider request or movie-folder
operation performed. Xcode's normal unsigned build did run its standard build-product LaunchServices step.

## Independent review follow-ups — 2026-10-28

- I1 (Important, fix implemented, awaiting re-review): ancestor traversal used O_RDONLY, which can require list access beyond the
  search permission needed to reach valid app-held storage. Use O_SEARCH for traversal and add a search-only
  parent regression while preserving no-follow/type/device safeguards.
- I2 (Important, open): cancellation before synchronous Data.write does not prevent atomic output appearing
  after sheet closure during an in-progress write. Stage bytes away from UI and serialize a short atomic
  publication with close/cancellation. Discard staged bytes on cancellation/failure, preserve existing destination,
  and keep destination access alive through publication. A deterministic held-stage regression must prove no
  publish or temp leak after closure. Approved cancellation behavior is preserved, not relaxed.

Same Worker and Reviewer retain both findings. Earlier passing counts/build are checkpoints, not final evidence
for the forthcoming fixes. User said continue; implementation authorization remains active, no phase advanced.

I1 regression RED observed at `/private/tmp/R110-05-I1-red.log`; changed only root/nonfinal traversal to O_SEARCH.
Target stays O_RDONLY, preserving no-follow/type/device checks. Updated focused FileSystem suite: 8 tests passed.
I2 held-stage cancellation/success tests authored before staging implementation; RED check in progress.

Follow-up implementation checkpoint:
- I1 + I2 focused checks: 8 FileSystem and 25 host tests passed;
  `/private/tmp/R110-05-review-filesystem.log`, `/private/tmp/R110-05-review-host-focused.log`.
- I2 uses SupportExportSaveOperation on MainActor for final no-suspension gate/atomic rename, with independent
  off-main staging and cleanup. Revalidates evidence/privacy after staging. Reviewer re-review pending.
- I3 (Important, open): default configuration reads mint new UUID revisions on an absent settings record,
  making fresh-install support exports perpetually stale. Use existing readIfPresentHoldingAccess to project
  stable absence without writes. Missing settings defaults are distinct from busy/corrupt/unavailable reads.
  Add actual temporary-repository tests for stable absence, irrelevant settings and real privacy changes.
  Root confirmed this fixes approved fresh-install behavior without changing scope or persistence schema.

## Implementation delivery — 2026-10-28

I1, I2 and I3 are resolved. The same independent reviewer returned explicit PASS after source/test/evidence
re-review. No Critical or Important findings remain. Two new delegate access-default compiler warnings were
removed by moving unchanged protocol witnesses from a private extension into a normal same-file extension;
the reviewer confirmed unchanged access/behavior and retained PASS.

Final focused coherence evidence (not formal validation):

| Check | Result | Local raw evidence |
| --- | --- | --- |
| FileSystem measurement | 8 tests passed | `/private/tmp/R110-05-review-filesystem.log` |
| Common category reporting | 2 tests passed | `/private/tmp/R110-05-common-green.log` |
| Host export/UI/direct integration | 28 tests in 6 suites passed | `/private/tmp/R110-05-review-host-focused.log` |
| Final unsigned Debug app/Finder build | BUILD SUCCEEDED, exit 0 | `/private/tmp/R110-05-debug-build-delivery-final.log` |
| Independent review | PASS, all Important findings resolved | `/private/tmp/R110-05-review.md` |
| Whitespace | tracked diff and all 17 new issue files passed | `git diff --check` / no-index new-file checks |

The final build has no remaining delegate access warnings; it reports the standard AppIntents metadata-extraction
warning because the app has no AppIntents dependency. Focused host checks require the documented no-batch compiler
workaround; no original test sources were removed or hidden. The latest warning cleanup changes only extension
access defaults and was independently reviewed and compiled; identical behavior tests were not rerun solely for it.

Implementation details/evidence: `/private/tmp/R110-05-implementation-report.md`.
The source feature groups are `Features/LocalData`, `Features/Support`, Common `LocalStorage`, and FileSystem
`DirectoryStorageMeasurement.swift`, with matching tests and Settings/readiness routing changes.

SwiftLint, formal Validation Phase, rendered Light/Dark/resizing, live keyboard/VoiceOver, native save-panel and
sandbox qualification remain unperformed. No implementation commit, merge or push has been made. Existing
unrelated untracked files remain untouched. Approval of this implementation authorizes its implementation commit
only; formal validation still needs explicit authorization. Product documentation/tracker integration updates
remain deferred until the authorized feature-completion sequence.


## Approved naming and API refactor — 2026-10-28

All six review points and the refactor table were approved before implementation.

- Rename Support Export types/callbacks/properties to LocalDataExport and merge source/test features into LocalData.
- Use LocalDataExportWriter, LocalDataExportTemporaryFileWriting,
  SystemLocalDataExportTemporaryFileWriter and PreparedLocalDataExportFile; use LocalDataExportSources.
- Rename readinessStatuses(report:) to installationCheckSummary(report:).
- Rename supportPreparationGeneration to localDataExportPreparationRequestID (UInt64 stale-result token).
- Rename LocalStorageCategoryUsage to LocalStorageCategorySummary; retain LocalStorageCategory and LocalStorageReport.
- Replace DirectoryStorageMeasurement with DirectoryStorage, an instance struct with immutable maximumEntries and
  maximumDepth initializer configuration and nonstatic measure(at:) and traversal helpers. Preserve all traversal
  safeguards, completeness semantics and result types; update limit-specific tests to configure the instance.
- Match filenames, test names, UI strings and accessibility labels to the approved names.

Implementation applied. Focused coherence checks pass after refactor: 8 FileSystem tests, 2 Common tests and
28 host tests in six suites. Logs: /private/tmp/R110-05-refactor-filesystem.log,
/private/tmp/R110-05-refactor-common.log and /private/tmp/R110-05-refactor-host.log. Host harness compiles the
complete application sources with the previously documented no-batch workaround. Initial default module-cache
access failed under sandbox; rerun with writable temporary module/cache/config/security paths passed.
No old renamed symbols remain in Swift source. Tracked diff whitespace and renamed issue-file whitespace/line
length checks passed. The same independent reviewer returned explicit PASS with no findings; report appended to
/private/tmp/R110-05-review.md. Earlier app/Finder build evidence predates this refactor;
no new native app build or runtime qualification claimed. No implementation commit or formal Validation Phase
authorized yet.


## Approved Local Data window navigation — 2026-10-28

User approved moving the read-only Local Data pane out of Settings into a dedicated reusable window.
Add an internaldrive icon button immediately to the right of Log in the main interface, with Local Data
as tooltip/accessibility label. Repeated requests bring the existing window forward. Settings contains
configurable choices only. Preserve the existing table, Refresh and export flow; attach export sheets to
the Local Data window and cancel pending work on closure. Follow existing native window styling and
appearance inheritance. Implementation and focused coherence checks are in progress; no phase advance,
implementation commit or formal Validation Phase authorization.


Navigation coherence checkpoint: production host harness builds and 18 focused tests in four suites pass with
-Xswiftc -disable-batch-mode. Independent review identified I4: closing Main/Settings must not invalidate
readiness/export owned by the separate Local Data window. Same Worker/Reviewer pair is correcting parent-specific
cancellation and preserving processing observers while any participating window is visible. Final evidence pending.


Local Data window implementation complete; same independent Reviewer returned explicit PASS after I4 correction.
The main footer now places internaldrive Local Data immediately right of Log, with native icon-button tooltip and
accessibility label. Settings has its four configuration tabs again. LocalDataPane is now an NSViewController
owned by a dedicated 700 x 650 resizable Local Data window, with the existing table and export controls.
Repeated opens front the current window. Export and pending preparation track their actual parent; unrelated
Main/Settings closure preserves Local Data work, owning-window closure cancels it. Request ID and parent are
checked before async completion clears state. Processing observers persist while any participating window is visible.

Final production-source host harness build passed: /private/tmp/R110-05-local-data-window-build.log.
Final focused checks: 18 tests in four suites passed: /private/tmp/R110-05-local-data-window-tests.log.
Lifecycle coverage checks icon routing/reuse, Settings tab removal, retained export parent preservation across
unrelated window closure and cleanup on Local Data closure. The harness does not expose attachedSheet reliably;
these are coordinator ownership assertions, not live native sheet/save-panel qualification. Independent review
record: /private/tmp/R110-05-review.md. Tracked diff whitespace check passed. No rendered layout, Light/Dark,
keyboard/VoiceOver, native app launch or save-panel qualification performed. No SwiftLint/formal Validation Phase,
implementation commit, merge or push. Awaiting user implementation approval.


User approved the completed implementation on 2026-10-28, authorizing its implementation commit.
Formal Validation Phase remains pending explicit authorization; no merge or push authorized.
