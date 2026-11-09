# Previous issue acceptance scenarios

This record maps the closed GitHub issues #2–#15 to user-observable behavior and
the automated coverage retained in the repository. Unit and integration tests
are identified at their actual execution level. They are not described as full
app E2E tests. Issue #1 has its own installation matrix in
`INSTALLATION_READINESS.md`. Issue #9 remains a release gate even though its
tracking issue is closed.

## R100-02 — Authoritative outcomes and summaries

### R100-02-A1 — Inventory totals reflect visible immediate directories

**Given** a collection contains visible immediate directories, hidden entries,
files, and symlinks, **when** its processing snapshot is recorded, **then** the
total counts only visible immediate directories and details explain excluded,
ignored, preserved, and failed entries.

Coverage: `CollectionProcessingStoreTests`, `CollectionSummaryCoverageTests`,
and FileSystem directory snapshot tests cover inventory calculation. The
full-app report scenario below verifies the saved exact total and folder list
after relaunch; it seeds the complete saved snapshot directly in the isolated
acceptance store, so it does not claim to exercise Finder-triggered inventory.

**R100-02-A1-S1:** Given a complete saved inventory containing two visible
immediate directories while the collection also contains a hidden directory,
a regular file, and a symlink, when the host relaunches and opens the saved
report, then it shows `Folders (2)` and both visible folder names and omits the
hidden directory, file, and symlink.

Full-app coverage: `testSavedInventoryReportShowsExactVisibleFolderTotalAfterRelaunch`
in `MovieFolderPosters/MovieFolderPostersUITests/MovieFolderPostersUITests.swift`.
The XCUITest seeds the configured collection and complete saved result only in
its disposable acceptance store, launches and relaunches the host app, then
checks the report's exact folder count and names.

### R100-02-A2 — Interrupted or stale evidence remains explicit

**Given** a processing run is interrupted or its saved revision is stale,
**when** the collection summary is read, **then** it reports unavailable,
partial, interrupted, or stale evidence without substituting zero counts.

Coverage: `CollectionSummaryCoverageTests` and processing-store tests.
Execution level: host integration tests. Full-app relaunch and details
verification: `testSavedProcessingOutcomeAppearsInCollectionSummaryAfterRelaunch`
in `MovieFolderPosters/MovieFolderPostersUITests/MovieFolderPostersUITests.swift`.
It seeds an unresolved saved outcome, relaunches the isolated host, and asserts
that the details report remains Partial and does not report unknown evidence.

## R100-03 — Activity Log

### R100-03-A1 — Committed activity survives restart in order

**Given** host and Finder operations append concurrent activity,
**when** the Log is reopened after the writers finish, **then** committed records
appear in sequence and retention bounds are respected.

Coverage: `ActivityLogTests` and Common activity tests. Execution level: service
tests. Full-app populated Log ordering after relaunch:
`testActivityEntriesRemainOrderedAfterRelaunch` in
`MovieFolderPosters/MovieFolderPostersUITests/MovieFolderPostersUITests.swift`.
The test creates two collections through the host UI, relaunches, and verifies
their committed Activity entries remain in order. Retention-boundary behavior
remains covered at the service level.

### R100-03-A2 — Clearing activity preserves product state

**Given** activity and processing outcomes/configuration both exist,
**when** the user clears Activity in Log, **then** activity is empty while
outcomes, matches, configuration, and folder icons remain unchanged.

Coverage: Log service isolation tests and
`testClearingActivityPreservesCollectionAcrossRelaunch` in
`MovieFolderPosters/MovieFolderPostersUITests/MovieFolderPostersUITests.swift`.
The full app journey checks activity removal, full configuration equality,
processing-record equality including a confirmed movie identity, and continued
ownership of an installed icon in the isolated collection after clearing and
relaunching. Match and icon fixtures are created only inside the disposable test
root.

### R100-03-A3 — Activity contains no private values

**Given** operations include credentials, paths, bookmarks, movie names, and
provider errors, **when** the activity is persisted and displayed, **then** only
the fixed safe event description is retained.

Coverage: Common activity redaction tests and
`testPrivateCollectionActivityDoesNotExposeNameOrPath` in
`MovieFolderPosters/MovieFolderPostersUITests/MovieFolderPostersUITests.swift`.
The full-app test clears prior public history in its isolated store, enables
private collection history, saves a collection change, and verifies the Log
shows the safe omission message without the collection name or path. Broader
path, movie-name, and provider-error redaction remains covered at the service
level.

## R100-04 — Recovery

### R100-04-A1 — Recovery waits for a later authorized invocation

**Given** processing stops after a temporary provider failure or process loss,
**when** a later authorized Finder invocation occurs, **then** eligible work
resumes after shared backoff and completed writes are not repeated.

Coverage: `ProcessingRecoveryTests`, processor recovery-resume tests,
`cachedRuntimeHonorsDurableRecoveryMode` in
`MovieFolderPosters/MovieFolderPostersFinderTests/FinderIntegrationTests.swift`,
and the isolated process-death probe in `scripts/test-recovery-process.sh`.
These exercise the recovery runtime and process coordination without registering
the extension in Finder. Full host-to-Finder E2E is BLOCKED: the Acceptance
scheme launches only the host UI target, and Finder does not consume the host's
isolated acceptance-root argument. Registering the extension would use its real
App Group container, so this test setup cannot safely isolate that flow.

**Isolated Finder-test preflight (2026-11-08):** an isolated host/extension
test path was selected for investigation, but this machine cannot currently
sign or register it safely. The UI-test runner has no App Group entitlement;
the host and production Finder extension both name
`group.dag.fikios.MovieFolderPosters`. `security find-identity -v -p
codesigning` reports zero valid identities. `codesign -d --entitlements :-`
reports invalid entitlement blobs for the built host and Finder extension,
which macOS ignores. A separate acceptance App Group therefore cannot be
verified or registered here. The full Finder journey remains BLOCKED pending a
valid development signing identity, a provisioned test App Group, and an
isolated Finder-extension registration environment. No extension was registered.

**User decision (2026-11-08):** signing is not available yet. Keep R100-04-A1
and A2 marked BLOCKED, defer this signing-dependent work, and continue with the
next acceptance item. Revisit this path after the development identity and
test-group provisioning are available.

**Selected remediation path:** add a dedicated acceptance host and Finder
extension build, both using a test-only App Group and a disposable movie root;
add full-app UI journeys for later-invocation recovery and suppression of
automatic retries after conclusive manual outcomes. This requires separate
Xcode targets, entitlements, a test scheme, and target-aware storage composition
in `MovieFolderEnvironment`/Finder service setup. The implementation proposal
and execution remain pending until valid signing and test-group provisioning
are available; current production storage and Finder registrations will not be
used for these journeys.

### R100-04-A2 — Manual outcomes never repeat automatically

**Given** a folder is classified Not found or Several matches,
**when** Finder revisits it after cooldown, reload, or process restart,
**then** no new provider search occurs until an explicit manual action.

Coverage: `conclusiveResultsDoNotScheduleAutomaticRetry` and manual-resolution
tests in `Packages/Common/Tests/CommonTests/Processing/`. Full Finder callback
E2E is BLOCKED for the same extension/App Group isolation limitation described
for R100-04-A1.

### R100-04-A3 — Recovery mode gates every mutation entry point

**Given** recovery mode is enabled while host/Finder work is pending,
**when** automatic, cached, manual, or stale-process work reaches admission,
**then** no disallowed mutation occurs and settings/diagnostics remain usable.

Coverage: recovery admission and mutation-boundary integration tests, plus
`testRecoveryModePersistsAndLeavesSettingsAndLogAvailable` in
`MovieFolderPosters/MovieFolderPostersUITests/MovieFolderPostersUITests.swift`.
The full-app test verifies the host gate survives relaunch and keeps Settings
and Log available. Cross-process mutation fencing remains covered at the
Finder/runtime integration level; a signed host-plus-Finder full-app journey
remains BLOCKED by the isolation limitation above.

## R100-05 — Manual resolution

### R100-05-A1 — Opening results is read-only; search needs an explicit action

**Given** an unresolved folder has saved evidence, **when** the user opens
Unresolved Results and then Choose Movie, **then** opening either surface does
not start a provider search; Search is enabled only for the explicit search
action, and results are not applied until the user selects a candidate.

Full-app coverage: `testChooseMovieUsesSavedLanguageAndSearchesDeterministicFixture`
in `MovieFolderPosters/MovieFolderPostersUITests/MovieFolderPostersUITests.swift`.

### R100-05-A2 — Canceling manual resolution preserves the unresolved outcome

**Given** a selected folder has conflicting movie evidence, **when** the user
opens Choose Movie and cancels, **then** the conflict remains unresolved and
no movie ID is committed.

Full-app coverage: `testConflictGuidanceLeadsToAuthoritativeManualSelection`
in `MovieFolderPosters/MovieFolderPostersUITests/R12004LocalInformationUITests.swift`.

### R100-05-A3 — Explicit selection commits authoritative identity safely

**Given** conflicting evidence requires human review, **when** the user
explicitly searches, selects a candidate, and applies it, **then** the chosen
movie ID and explicit-selection provenance persist after relaunch; a later
contradictory local NFO does not replace the decision or its owned icon.

The same full-app journey verifies the canceled state first, applies the
selected candidate, relaunches, and checks saved identity/provenance and icon
retention using only its disposable acceptance collection.

### R100-05-A4 — Selected retry changes only eligible targets

**Given** one selected failed folder has new local matching information and a
sibling remains unresolved, **when** the user requests Retry Selected,
**then** the selected folder is reassessed, while the unrelated sibling's
saved outcome remains unchanged.

Full-app coverage: `testRetrySelectedReassessesChangedLocalInformation` in
`MovieFolderPosters/MovieFolderPostersUITests/R12004LocalInformationUITests.swift`.

### R100-05-A5 — Canceling retry stops later writes and preserves other outcomes

**Given** a selected retry is suspended during provider search while unrelated
folder outcomes already exist, **when** the retry is canceled, **then** the
selected folder is recorded as interrupted, no poster write follows, and the
unrelated outcomes remain unchanged.

Acceptance integration coverage: `selectedRetryCancellationPreservesOtherMembers`
in `Packages/Common/Tests/CommonTests/Processing/MovieFolderProcessorSelectedRetryTests.swift`.
This uses a controlled provider and disposable filesystem/persistence fixture;
the selected-row cancellation state machine is also covered by
`CollectionResultsViewModelTests/cancellationDrainsBeforeAllowingReplacement`.

These isolated host journeys establish the manual interface, selection, and
retry behavior. They do not claim that the Finder extension callback was
qualified against a registered Finder process; signing-dependent extension
qualification remains separately blocked.

## R100-06 — Access-token setup

### R100-06-A1 — Candidate token is tested before replacement

**Given** a saved token and a collection with a confirmed movie decision,
**when** the user enters a candidate and cancels the confirmation, **then** the
candidate is not saved and the existing token remains usable.

**Given** the same saved token and configured collection/match state, **when**
the user confirms replacement with a valid candidate, **then** the candidate is
tested and saved, the success message is shown, and the collection and confirmed
movie decision remain unchanged after relaunch.

Coverage: `AccessTokenServiceTests` and presentation tests. Execution level:
service/presentation tests plus full-app acceptance tests
`testCanceledReplacementDoesNotValidateOrPersistCandidate` and
`testValidReplacementIsConfirmedAndPreservesCollectionAndMatch` in
`MovieFolderPosters/MovieFolderPostersUITests/MovieFolderPostersUITests.swift`.
These are full-app XCUITest journeys providing combined acceptance and E2E
coverage.
The UI tests use the existing isolated Debug acceptance launch and a disposable
file-backed fake token store; validation accepts only known non-secret test
sentinels and never contacts TMDb.

### R100-06-A2 — Safe outcomes do not reveal the token

**Given** validation returns invalid, offline, or success, **when** the result
is shown or exported, **then** the states are distinct and no token appears in
UI, error text, or diagnostics.

Coverage: service and export redaction tests. Execution level: integration
tests plus full-app acceptance tests
`testRejectedReplacementPreservesExistingTokenAndRedactsCandidate` and
`testOfflineReplacementShowsSafeOutcomeWithoutSavingCandidate` in
`MovieFolderPosters/MovieFolderPostersUITests/MovieFolderPostersUITests.swift`.
These are full-app XCUITest journeys providing combined acceptance and E2E
coverage.
The UI tests assert the distinct fixed result, candidate absence from accessible
UI content and storage, and that invalid validation leaves the original saved
token usable. Existing service tests continue to cover safe diagnostics/export.

## R100-07 — Usability and accessibility

### R100-07-A1a — Empty setup and Log controls are accessible

**Given** an isolated app has no configured collections, **when** Main and Log
are opened, **then** Main explains how to add a collection and the primary Add
and Log controls expose useful accessible names.

Full-app XCUITest: `testEmptyStateAndLogControlsExposeAccessibleDescriptions`
in `MovieFolderPosters/MovieFolderPostersUITests/MovieFolderPostersUITests.swift`.

### R100-07-A1b — Settings is reachable from the keyboard

**Given** Main is open, **when** the user presses Command-comma, **then** the
existing Settings window opens and its TMDb controls are reachable.

Full-app XCUITest: `testCommandCommaOpensSettingsFromMain` in
`MovieFolderPosters/MovieFolderPostersUITests/MovieFolderPostersUITests.swift`.

### R100-07-A1c — Keyboard removal does not modify the movie folder

**Given** a selected configured collection, **when** the user presses Delete,
**then** the collection is removed from app configuration, remains absent after
relaunch, and its actual folder remains on disk.

Full-app XCUITest: `testDeleteRemovesSelectedCollectionButKeepsFolder` in
`MovieFolderPosters/MovieFolderPostersUITests/MovieFolderPostersUITests.swift`.

### R100-07-A1d1 — Light and Dark choices persist and apply to app windows

**Given** the host app is using isolated acceptance preferences, **when** the
user selects Light or Dark, closes and reopens Settings, and relaunches the app,
**then** the selected choice remains visible and app windows use the chosen mode.

Full-app XCUITest: `testAppAppearanceSelectionPersistsAcrossWindowCloseAndRelaunch`
in `MovieFolderPosters/MovieFolderPostersUITests/MovieFolderPostersUITests.swift`.
The acceptance launch stores the choice under the disposable shared test root;
normal launches continue using standard user defaults. Existing
`appearanceAndWindowReuseCoverEveryHostFlow` in
`MovieFolderPosters/MovieFolderPostersTests/Application/CoordinatorLifecycleTests.swift`
checks effective appearance on existing, reopened, and newly presented windows.

### R100-07-A1d2 — High contrast, resize, asynchronous focus, and VoiceOver

**Given** the app is used with increased contrast and its core windows and
controls, **when** the user resizes or reopens windows and asynchronous updates
finish, **then** status remains understandable without color alone and keyboard
and VoiceOver focus remains usable.

Scenario execution:

- **A1d2-S1 — Visible status and reopen.** Given a collection has completed the
  host access preflight, when its row is shown and Log is closed and reopened,
  then the explanatory status remains visible and Log's source and search
  controls remain usable. Coverage: full-app XCUITest
  `testCollectionStatusAndCoreWindowsRemainUsableAfterLogReopen` in
  `MovieFolderPosters/MovieFolderPostersUITests/MovieFolderPostersUITests.swift`.
  **PASS** — the test found the full status text, confirmed Add collection and
  Log controls were hittable, closed Log, reopened it, and found the history
  source and search controls. Evidence:
  `/private/tmp/mfp-r10007-point7-reopen-final2.log`.
  This verifies textual status in the normal appearance; it does not establish
  contrast-mode behavior.
- **A1d2-S2 — Resize.** Given the Main window is open, when its size changes,
  then its frame changes and its collection controls remain usable. Coverage:
  full-app XCUITest `testCollectionStatusAndCoreWindowsRemainUsableAfterLogReopen`
  in `MovieFolderPosters/MovieFolderPostersUITests/MovieFolderPostersUITests.swift`.
  **PASS** — the test resized Main through the macOS Accessibility API, verified
  the frame changed, confirmed Add collection remained hittable, and restored
  the initial size. Log resizing remains unverified: macOS did not expose its
  utility window through the host process Accessibility window list. The
  runner was explicitly enabled under Privacy & Security → Device Control and
  Data Access. Evidence: `/private/tmp/mfp-r10007-point7-resize-accessibility-final.log`.
- **A1d2-S3 — Asynchronous update preserves keyboard focus.** Given the Log
  search field is focused, when a committed activity entry triggers an async
  reload, then the updated retained-entry count appears and subsequent keyboard
  input still edits the search field. Coverage: full-app XCUITest
  `testLogAsyncSourceReloadKeepsKeyboardFocus` in
  `MovieFolderPosters/MovieFolderPostersUITests/MovieFolderPostersUITests.swift`.
  **PASS** — an activity event was written under the disposable test root; Log
  displayed the incremented count and accepted further typing without another
  click. Evidence: `/private/tmp/mfp-r10007-point7-retry4.log`.
- **A1d2-S4 — Increased contrast.** Given macOS Increased Contrast is enabled,
  when status and controls are displayed, then text and controls remain
  distinguishable. Coverage: full-app XCUITest
  `testCollectionStatusAndControlsRemainUsableWithIncreasedContrast` in
  `MovieFolderPosters/MovieFolderPostersUITests/MovieFolderPostersUITests.swift`.
  **PASS** — with the actual macOS setting temporarily enabled through System
  Settings, the test found the explanatory status and confirmed Add collection
  and Log were hittable. The setting was restored to off, its initial state.
  Evidence: `/private/tmp/mfp-r10007-point7-high-contrast.log`.
- **A1d2-S5 — VoiceOver navigation and announcement.** Given VoiceOver is
  enabled, when navigating collection status and Log after an asynchronous
  update, then reading order, announcements, and focus remain understandable.
  Coverage: full-app XCUITest
  `testVoiceOverSpeaksLogSearchAfterAsyncActivityReload` in
  `MovieFolderPosters/MovieFolderPostersUITests/MovieFolderPostersUITests.swift`.
  **PASS** — with VoiceOver temporarily enabled through System Settings, the
  test captured the search-field announcement, waited for a committed isolated
  activity event and async reload, then confirmed VoiceOver spoke subsequent
  search input. VoiceOver was restored to off, its initial state. Evidence:
  `/private/tmp/mfp-r10007-point7-voiceover-restoration.log`. On this runner,
  starting VoiceOver from off through the XCUITest service timed out, so local
  execution requires VoiceOver to be pre-enabled; the test preserves its prior
  state and restores it when its own enable call succeeds.

Point summary: 5 scenarios — 5 PASS, 0 FAIL, 0 BLOCKED. Four full-app UI tests
cover status/reopen and Main resizing, asynchronous keyboard focus, Increased
Contrast, and VoiceOver speech. Log-window resizing is outside the verified
resize result because macOS did not expose that utility window through the
host process Accessibility window list.

## R100-08 — Cached artwork repair

### R100-08-A1 — Explicit visit repairs only valid source artwork

**Given** a matched folder has missing/corrupt cached artwork,
**when** an authorized processing visit attempts repair,
**then** valid provider bytes replace the source cache at most once that visit;
invalid bytes retain the saved match and existing icon.

Coverage: `MovieFolderProcessorTests` and integration tests. Execution level:
Common integration tests. Full Finder-triggered persistent-icon E2E remains
absent.

BDD scenarios:

- **R100-08-A1-S1:** Given a confirmed saved movie decision and truncated cached
  poster bytes after the search cache expires, when a later authorized
  processing visit runs, then it repairs the source cache from the saved poster
  path without another movie search and retains the match.
- **R100-08-A1-S2:** Given a corrupt cached poster and a provider returning
  invalid artwork, when the repair visit runs, then invalid bytes do not replace
  the cache and the saved movie decision remains.
- **R100-08-A1-S3:** Given a folder with a foreign or user-replaced icon, when
  cached artwork repair runs, then the foreign icon is not replaced.
- **R100-08-A1-S4:** Given a valid owned folder icon and corrupt source cache,
  when repair runs, then only the source cache is repaired and the owned icon
  is not assigned again.

Automated coverage: `corruptArtworkRepairsFromSavedPosterPathWithoutSearchingAgain`,
`invalidProviderArtworkDoesNotReplaceCorruptCacheOrLoseSavedDecision`,
`corruptArtworkDoesNotReplaceForeignFolderIcon`, and
`corruptSourceCacheRepairDoesNotRewriteOwnedFolderIcon` in
`Packages/Common/Tests/CommonTests/Processing/MovieFolderProcessorRetryTests.swift`.
These exercise the production processor, provider boundary, persistence, and
temporary filesystem fixtures; they are processor integration tests, not full
Finder E2E.

Full-app Finder E2E status: **BLOCKED**. Executing the required Finder callback
and observing persistent icon behavior requires a signed, isolated Finder
extension/App Group host. Signing is not available, and the user directed that
this signing-dependent test remain annotated while work continues on other
scenarios. No live Finder registration or user collection was used.

## R100-09 — Release qualification

### R100-09-A1 — Candidate installation and release channels qualify

**Given** a declared supported system and release candidate,
**when** fresh-install/upgrade, Debug/Release transport, live provider, signing,
notarization, attribution, and icon-persistence checks run,
**then** each release claim has recorded passing evidence.

Status: BLOCKED as a complete scenario. Signed packaging, notarization,
Gatekeeper, install/upgrade, live TMDb, Finder activation, and persistent icon
checks are release prerequisites unavailable for this acceptance run. The
roadmap keeps the release gate open; focused tests and development-signed test
bundles do not satisfy release qualification.

## R110-01 — Collection setup

Collection creation and language inheritance have existing XCUITest coverage.
Focused configuration tests cover identity, naming, duplicates, and denial.
Full drag/drop versus picker parity is covered by the isolated native UI journey below.

### R110-01-A1 — A friendly name preserves the authorized root

**Given** a collection added through the native picker, **when** the user
saves a new display name and relaunches, **then** Main shows the new name and
the saved collection ID, stable identity, path, and authorization revision
are unchanged. Covered by `testCollectionRenamePreservesAuthorizedRoot`.

### R110-01-A2 — A disconnected collection remains identifiable and recoverable

**R110-01-A2-S1:** Given a saved collection with a stable identity points to a
disconnected volume, when the host app launches, then Main identifies the
volume as disconnected, offers the enabled **Locate Folder…** action, and
preserves the collection ID, path, and identity.

Full-app coverage: `testDisconnectedCollectionRetainsIdentityAndOffersLocateFolder`
in `MovieFolderPosters/MovieFolderPostersUITests/MovieFolderPostersUITests.swift`.
The test seeds a nonexistent mount path and saved identity in its disposable
acceptance store; no real volume is mounted or unmounted. It checks the host
row's accessible disconnected status, the recovery action, and configuration
equality after the app loads. This verifies host presentation and recovery
availability, not Finder extension behavior or actual volume mount events.

### R110-01-A3 — Dragging and picking a collection persist equivalent choices

**R110-01-A3-S1:** Given an isolated host and two disposable collection folders,
when the user adds the first folder with the native picker and drags the second
folder into collection setup, then each folder is selected and saved with its
own path, stable filesystem identity, default matching and processing choices,
and private-history setting.

Full-app XCUITest: `testFolderDropMatchesPickerCollectionSetup` in
`MovieFolderPosters/MovieFolderPostersUITests/MovieFolderPostersUITests.swift`.
The Acceptance scheme builds a test-only AppKit drag-source app. The test posts
a native mouse drag of one local file URL, checks AppKit reports a copy drop,
then verifies the selected folder in the setup form and compares the persisted
folder identities and default choices. Both folders and app storage live under
the test's disposable `/private/tmp/MovieFolderPostersAcceptance/<UUID>` root;
the helper is not part of the production host or release scheme.

### R110-01-A4 — Duplicate roots never create a second collection

**Given** a filesystem root is already configured, **when** the user tries to
add that root again or commits a prepared overlapping root, **then** the
operation is rejected and the original collection and authorization remain
unchanged.

Coverage: `DirectoryConfigurationServiceCoverageTests/addingDuplicatePreservesOneCollection`
and `DirectoryConfigurationEditTests/finalCommitRechecksOverlap`.

### R110-01-A5 — Access denial does not imply a grant or lose collection identity

**Given** a previously configured root can no longer be authorized, **when**
the host checks access, **then** it reports the recoverable reauthorization
state and retains the saved collection identity. Enabling Finder integration
does not stand in for this filesystem authorization.

Coverage: `DirectoryConfigurationServiceCoverageTests/failedAuthorizationProducesRecoverableAvailability(_:)`
and full-app recovery presentation through
`testDisconnectedCollectionRetainsIdentityAndOffersLocateFolder`.

## R110-02 — Pause and exclusions

### R110-02-A1 — In-flight mutations respect pause and exclusion

**R110-02-A1-S1:** Given an explicit poster refresh is suspended during provider
work, when the collection is paused before the mutation boundary, then the
refresh is rejected and no folder icon is assigned.

**R110-02-A1-S2:** Given an explicit poster refresh is suspended during
provider work, when its target child is excluded before the mutation boundary,
then the refresh is rejected and no folder icon is assigned.

**R110-02-A1-S3:** Given a child is excluded and unrelated saved outcomes exist,
when processing starts or the child is included again, then the excluded
identity and unrelated outcomes are reconciled without clearing suppression or
rewriting a foreign icon.

Coverage: `policyChangeDuringManualSearchPreventsPosterChange(_:)` suspends a
provider request, commits a pause or exclusion to saved configuration, then
verifies the mutation is rejected; `pausedCollectionDoesNotContactProvider`,
`rejectedExcludedManualActionPreservesOutcome(_:)`,
`exclusionFollowsRenamedFolder`, `inclusionChangesReconcileExcludedAndIncludedRecords`,
and `inclusionChangePreservesUnrelatedOutcomesAndRejectsStaleWriter` cover
policy, stable identity, suppression, and saved-outcome behavior in isolated
processor/store tests.

**Full cross-process Finder E2E: BLOCKED.** The tests above exercise the
persisted policy boundary in-process. Firing a Finder callback from a separately
signed extension process and observing the same in-flight fence still requires
the isolated signed Finder extension/App Group setup. Signing is unavailable,
as directed; no Finder registration or user collection was used.

## R110-03 — Filtering and private history

### R110-03-A1 — Filters show structured records and remain keyboard usable

**Given** saved outcomes and Activity/Network events contain different
categories and severities, **when** the user searches and filters in Log,
**then** only matching structured rows appear and keyboard operation is
available.

Coverage: `LogViewModelTests` and AppKit presentation tests. Full-app
XCUITest `testStructuredLogFiltersShowOnlyMatchingHistoryEntry` seeds three
typed Activity records in isolated storage, then uses the actual Log window to
combine category, severity, and message search and verifies only the matching
row remains visible. Full-app XCUITest `testStructuredNetworkLogFiltersShowOnlyMatchingRequest`
seeds successful and failed terminal events through the real persisted Network-history
service under isolated storage, then filters them in the actual Log window.
`testClearingActivityPreservesCollectionAcrossRelaunch`
also verifies that selecting Error hides an informational entry and clearing
while filtered removes the hidden entry from persistent history. The host
presentation test `structuredFiltersCombineAndControlsRemainKeyboardTraversable`
adds empty-intersection, information-result, keyboard-loop, and source-to-search
focus coverage, including a Network source fixture.

BDD detail:

- **R110-03-A1-S1:** Given poster, application and Finder entries, when the
  user combines Poster Actions, Error and a matching message search, then only
  the poster error row appears with its category and severity.
- **R110-03-A1-S2:** Given the same entries, when Application is combined with
  Error, then no rows appear.
- **R110-03-A1-S3:** Given the same entries, when Information is combined with
  an application-startup search, then the application information row appears.
- **R110-03-A1-S4:** Given the Log controls, when keyboard focus advances from
  History source, then Search receives focus and the configured control loop
  remains connected through Clear back to History source.
- **R110-03-A1-S5:** Given successful and failed Network history entries, when
  the user selects Network and combines Movie Search, Information and the
  response-message search, then only the matching structured request appears.

Automated coverage for S1–S5: `structuredFiltersCombineAndControlsRemainKeyboardTraversable`
in `MovieFolderPosters/MovieFolderPostersTests/Features/Log/LogTableCoverageTests.swift`.
S5 also has full-app coverage in
`testStructuredNetworkLogFiltersShowOnlyMatchingRequest`.

### R110-03-A2 — Private mode governs new history and preserves old history

**Given** a collection has existing history, **when** Private is enabled and
new operations occur, **then** new events omit identifying collection data and
existing history follows the documented retain-until-clear policy.

**R110-03-A2-S1:** Given an existing public collection history event, when the
user enables Private and relaunches, then the earlier event remains unchanged
and the new settings event contains no collection name or path.

Full-app coverage: `testPrivateCollectionHistoryPersistsAcrossRelaunch` in
`MovieFolderPosters/MovieFolderPostersUITests/MovieFolderPostersUITests.swift`.
The isolated XCUITest verifies the public event before the change, compares the
same entry after relaunch, and checks that the new private settings event is
redacted. The configuration/history unit tests continue to cover the
retain-until-clear and payload rules independently.

## R110-04 — Finder utilities

GitHub issue #13 requires commands to validate selected roots/children,
distinguish unconfirmed identity, and reveal only explicitly selected
authorized results. It also names four user actions: inspect saved evidence,
reveal unresolved folders, copy a confirmed title, and copy a movie identifier.
The roadmap still marks this deliverable planned while issue #13 is closed;
preserve the discrepancy for tracker reconciliation.

### R110-04-A1 — Inspection opens current saved evidence without mutation

**Given** the host has loaded a collection and a Finder inspection request
arrives for an identified child, **when** the host opens Processing Details,
**then** it reuses the details window, shows saved evidence without marking an
unconfirmed identity as verified, and does not change configuration or the
clipboard.

Coverage: `ConfigurationCoordinatorCoverageTests/firstContextMenuRequestLoadsConfigurationAndReusesInspection`
and `ConfigurationCoordinatorCoverageTests/processingDetailsRequestDoesNotMutateConfiguration`.
These exercise real AppKit coordinator/windows with controlled services; they
do not execute a Finder extension callback. `MovieFolderFinderActionServiceTests/inspectionStatusUsesCurrentIdentityAndKeepsEvidenceQualified`
and `inspectionStatusRejectsReplacementChildIdentity` cover live child identity
and qualify saved evidence; `CollectionDetailsCoverageTests/interruptedManualReportKeepsUnknownEvidenceExplicit`
checks the read-only report labels saved decisions and unavailable identity
evidence accurately.

### R110-04-A2 — Reveal acts on the exact selected authorized unresolved folders

**Given** saved unresolved children have current filesystem identities,
**when** the user selects two rows and requests Reveal, **then** only those
folders are sent to Finder in natural order after authorization and identity
checks; if any identity differs, the entire reveal is rejected.

Coverage: `MovieFolderFinderActionServiceTests/resultsViewModelRevealsExactSelectionAndSuppressesLateEffects(_:)`,
`MovieFolderFinderActionServiceTests/rejectsWholeRevealWhenOneIdentityDiffers()`,
and `CollectionResultsViewModelTests/revealUsesExactNaturalSelectionAndRejectsIdentitylessRows`.
The service test uses a platform probe and disposable storage, so it verifies
the validated selection and platform boundary without invoking Finder.

### R110-04-A3 — Copy only currently verified movie metadata

**Given** saved evidence identifies a current child and explicitly confirms its
movie, **when** the user requests Copy Title or Copy Identifier, **then** the
clipboard effect contains only the verified title or identifier. An absent
title, stale evidence, replaced child, or unverified provenance is rejected;
an identifier may still be copied when no title is saved.

Coverage: `MovieFolderFinderActionServiceTests/copiesVerifiedFailureAndRetainsSettingsFence`,
`MovieFolderFinderActionServiceTests/identifierWithoutTitleAndStaleEvidence()`,
`MovieFolderFinderActionServiceTests/rejectsInvalidUtilityEvidence(_:)`,
`MovieFolderFinderActionServiceTests/platformCallRetainsFenceAndReportsClipboardFailure()`,
and `MovieFolderFinderActionServiceTests/invalidationSuppressesPreparedClipboardEffect()`.
These use disposable repositories and a clipboard probe; they never write to
the system clipboard.

**Finder full-app E2E: BLOCKED.** Invoking the Finder extension context menu
and observing the handoff into the host requires the isolated signed Finder
extension/App Group setup. Signing is not available, per the user's direction;
the test remains annotated as blocked. The service and coordinator tests above
are not substitutes for that E2E journey. No Finder registration or live
collection was used.

## R110-05 — Local data and support export

### R110-05-A1 — Export contains only reviewed safe data

**Given** local categories contain paths, access grants, credentials, and
diagnostics, **when** the user selects categories, previews, and saves,
**then** the saved bytes exactly match the preview and exclude secrets, grants,
and identifying paths by default.

Coverage: export service/publication tests and
`testLocalDataMeasurementAndPreviewInvalidation`. The full app test writes
through the native save panel and compares the file with the exact preview.
The host integration tests exercise additional redaction and failure cases.

### R110-05-A2 — Storage estimates identify their scope

**Given** local storage categories have measurable sizes,
**when** the user opens the inspector, **then** estimates identify the measured
category and time and unavailable/corrupt data is not shown as zero.

Coverage: storage-report tests plus
`LocalDataPresentationTests/unavailableAndIncompleteEstimatesAreNotPresentedAsZero`
in `MovieFolderPosters/MovieFolderPostersTests/Features/LocalData/LocalDataExportTests.swift`.
The host AppKit test uses a disposable directory containing a skipped symlink
and a missing host-support root; partial zero estimates display as Incomplete,
and unavailable estimates display as Unavailable. Full-app UI inspector
coverage for scope and capture time is in
`testLocalDataMeasurementAndPreviewInvalidation`.

### R110-05-A3 — Changing the export selection invalidates the preview

**Given** an isolated host has opened the Local Data export sheet and Save is
disabled, **when** the user generates a JSON preview and then toggles storage
estimates, **then** the previous preview clears and Save is disabled again.

Automated coverage: `testLocalDataMeasurementAndPreviewInvalidation` in
`MovieFolderPosters/MovieFolderPostersUITests/MovieFolderPostersUITests.swift`.
The test checks that the preview parses as JSON and excludes the isolated
storage path. It generates a fresh preview before exercising publication.

## R120-01 — Verified aliases and language

Full-app scenarios for language persistence, inheritance, manual search, and
spelling suggestion exist in `docs/acceptance/R120-01.md` and the XCUITest
target. Provider provenance and ambiguous-alias behavior have integration
coverage. No separate full-app UI test seeds competing direct/alias evidence:
issue #15's acceptance criterion is that deterministic provider fixtures
preserve ambiguous IDs in the saved processor result, which
`competingInternationalEvidencePersistsSeveralMatches` verifies. The existing
Choose Movie XCUITest covers the user-facing explicit selection route. A
second UI journey would duplicate that route without strengthening the
provider-evidence assertion.

## Execution record

The isolated macOS acceptance runs passed the listed scenarios. The first Local
Data run failed to find the capture timestamp when querying only the label.
The passing rerun queried both label and value. Evidence is in
`/private/tmp/mfp-acceptance-gap-retry.log` and
`/private/tmp/mfp-acceptance-gap-pair.log`.

| Coverage | Test | Result |
| --- | --- | --- |
| R100-05-A1, unresolved Choose Movie waits for explicit Search and selection | `testChooseMovieUsesSavedLanguageAndSearchesDeterministicFixture` | PASS: `/private/tmp/mfp-acceptance-gap-build/Logs/Test/Test-MovieFolderPostersAcceptance-2026.11.09_06-42-58-+0100.xcresult` (1 full-app XCUITest, 0 failures) |
| R100-05-A2/A3, cancel preserves conflict; explicit movie choice persists with explicit provenance and owned icon | `testConflictGuidanceLeadsToAuthoritativeManualSelection` | PASS: `/private/tmp/mfp-r10005-manual-resolution.xcresult` (1 full-app XCUITest, 0 failures) |
| R100-05-A4, selected retry reassesses changed target and preserves unrelated unresolved sibling | `testRetrySelectedReassessesChangedLocalInformation` | PASS: `/private/tmp/mfp-r10005-selected-retry.xcresult` (1 full-app XCUITest, 0 failures) |
| R100-05-A5, cancellation interrupts only selected retry and prevents poster writes | `selectedRetryCancellationPreservesOtherMembers` | PASS: focused Swift Testing run; 1 test passed |
| R110-01-A1, friendly rename preserves root authorization and matching choices | `testCollectionRenamePreservesAuthorizedRoot` | PASS: `/private/tmp/mfp-acceptance-rename.log` |
| R110-01-A4, duplicate roots and a late overlapping setup are rejected atomically | `addingDuplicatePreservesOneCollection`, `finalCommitRechecksOverlap` | PASS: `/private/tmp/mfp-r11001-collection-edges.xcresult` (18 tests / 23 parameter runs, 0 failures) |
| R110-01-A5, denied/invalid access remains recoverable without losing saved identity | `failedAuthorizationProducesRecoverableAvailability(_:)`, `testDisconnectedCollectionRetainsIdentityAndOffersLocateFolder` | PASS: focused service suite `/private/tmp/mfp-r11001-collection-edges.xcresult`; disconnected host UI `/private/tmp/mfp-r11001-a2-final.log` |
| R110-02-A1-S1/S2, pause or exclusion committed during suspended provider work rejects the poster mutation | `policyChangeDuringManualSearchPreventsPosterChange(_:)` | PASS: `/private/tmp/mfp-r11002-policy-regressions.log` (6 selected tests, including both parameter cases, 0 failures) |
| R110-02-A1-S3, inclusion reconciliation preserves unrelated saved outcomes and exclusion state | `inclusionChangesReconcileExcludedAndIncludedRecords`, `inclusionChangePreservesUnrelatedOutcomesAndRejectsStaleWriter` | PASS: same focused Swift Testing run, 0 failures |
| R110-02-A1, separately signed Finder process observes the in-flight fence | Finder extension/App Group UI journey | BLOCKED: signing unavailable as directed; service tests do not establish separate-process execution |
| R110-04-A1, Finder inspection routes to host details and reports current policy/evidence without confirming unverified data | `firstContextMenuRequestLoadsConfigurationAndReusesInspection`, `processingDetailsRequestDoesNotMutateConfiguration`, `inspectionStatusUsesCurrentIdentityAndKeepsEvidenceQualified`, `inspectionStatusRejectsReplacementChildIdentity`, `interruptedManualReportKeepsUnknownEvidenceExplicit` | PASS: coordinator `/private/tmp/mfp-r11004-coordinator-suite.xcresult` (6 tests); action service `/private/tmp/mfp-r11004-finder-actions-final.xcresult` (9 logical tests / 15 parameter runs); details `/private/tmp/mfp-r11004-details.xcresult`; all focused suites passed |
| R110-04-A2, reveal only selected current identities and reject whole request when any identity is invalid | `resultsViewModelRevealsExactSelectionAndSuppressesLateEffects(_:)`, `rejectsWholeRevealWhenOneIdentityDiffers()` | PASS: `/private/tmp/mfp-r11004-finder-actions-final.xcresult` (9 logical Swift Testing cases / 15 parameter runs, 0 failures) |
| R110-04-A3, copy only verified title/identifier and reject stale, replaced, or unverified evidence | `copiesVerifiedFailureAndRetainsSettingsFence`, `identifierWithoutTitleAndStaleEvidence()`, `rejectsInvalidUtilityEvidence(_:)`, `platformCallRetainsFenceAndReportsClipboardFailure()`, `invalidationSuppressesPreparedClipboardEffect()` | PASS: same final focused result bundle; 9 logical cases / 15 parameter runs, 0 failures |
| R110-04-A1–A3, invoke Finder context menu and complete Finder-to-host reveal/copy journey | Signed isolated Finder extension/App Group UI test | BLOCKED: signing unavailable as directed; service/coordinator tests do not qualify this E2E |
| R100-02-A1-S1, exact saved inventory report after relaunch | `testSavedInventoryReportShowsExactVisibleFolderTotalAfterRelaunch` | PASS: `/private/tmp/mfp-r10002-a1-final.log` (1 XCUITest, 0 failures) |
| R110-01-A2-S1, disconnected collection status, Locate Folder, and identity retention | `testDisconnectedCollectionRetainsIdentityAndOffersLocateFolder` | PASS: `/private/tmp/mfp-r11001-a2-final.log` (1 XCUITest, 0 failures) |
| R110-01-A3-S1, picker and native folder drag save equivalent collection choices | `testFolderDropMatchesPickerCollectionSetup` | PASS: `/private/tmp/mfp-acceptance-gap-build/Logs/Test/Test-MovieFolderPostersAcceptance-2026.11.09_00-13-48-+0100.xcresult` (1 XCUITest, 0 failures) |
| R100-08-A1-S1, saved match repairs from its poster path without re-search | `corruptArtworkRepairsFromSavedPosterPathWithoutSearchingAgain` | PASS: focused Swift Testing run, 1 test passed |
| R100-08-A1-S2, invalid provider artwork preserves cache and saved match | `invalidProviderArtworkDoesNotReplaceCorruptCacheOrLoseSavedDecision` | PASS: focused Swift Testing run, 1 test passed |
| R100-08-A1-S3, cached repair preserves foreign icon | `corruptArtworkDoesNotReplaceForeignFolderIcon` | PASS: focused Swift Testing run, 1 test passed |
| R100-08-A1-S4, source-only repair does not reassign owned icon | `corruptSourceCacheRepairDoesNotRewriteOwnedFolderIcon` | PASS: focused Swift Testing run, 1 test passed |
| R100-08-A1-S1–S4, Finder-triggered persistent-icon journey | Full Finder E2E requires the signed isolated extension/App Group setup | BLOCKED: signing unavailable; deferred by user decision |
| R100-09-A1, signed release candidate install/upgrade, provider, Gatekeeper, and persistent icon qualification | Release qualification matrix | BLOCKED: signing, notarization, live provider and Finder qualification prerequisites unavailable; roadmap release gate remains open |
| R120-A1, global language persists after relaunch | `testGlobalSearchLanguagePersistsAcrossRelaunch` | PASS: `/private/tmp/mfp-acceptance-gap-build/Logs/Test/Test-MovieFolderPostersAcceptance-2026.11.09_06-40-34-+0100.xcresult` |
| R120-A2, collection inherits global language and preserves explicit override | `testCollectionLanguageInheritanceAndOverridePersist` | PASS: same 2-test XCUITest result, 0 failures |
| R120-A3, Choose Movie discloses and uses effective language | `testChooseMovieUsesSavedLanguageAndSearchesDeterministicFixture` | PASS: `/private/tmp/mfp-acceptance-gap-build/Logs/Test/Test-MovieFolderPostersAcceptance-2026.11.09_06-42-58-+0100.xcresult` |
| R100-02-A2, saved partial evidence after host relaunch | `testSavedProcessingOutcomeAppearsInCollectionSummaryAfterRelaunch` | PASS |
| R100-03-A1, committed collection entries remain ordered after relaunch | `testActivityEntriesRemainOrderedAfterRelaunch` | PASS |
| R100-03-A2, clear preserves configuration, confirmed outcome, and icon | `testClearingActivityPreservesCollectionAcrossRelaunch` | PASS |
| R110-03-A1, app Log combines category, severity, and search and displays only matching Activity row | `testStructuredLogFiltersShowOnlyMatchingHistoryEntry` | PASS: `/private/tmp/mfp-r11003-filter-ui-verified.xcresult` (1 full-app XCUITest, 0 failures) |
| R110-03-A1-S5, app Log filters persisted Network request history | `testStructuredNetworkLogFiltersShowOnlyMatchingRequest` | PASS: `/private/tmp/mfp-r11003-network-ui-final2.xcresult` (1 full-app XCUITest, 0 failures) |
| R100-03-A3, private collection details omitted from Activity | `testPrivateCollectionActivityDoesNotExposeNameOrPath` | PASS |
| R100-04-A1, full host-to-Finder recovery after interruption | Full Finder E2E not present; isolated signing/App Group preflight blocked | BLOCKED |
| R100-04-A2, manual outcomes do not repeat through Finder callbacks | Full Finder E2E not present; isolated signing/App Group preflight blocked | BLOCKED |
| R100-04-A3, Recovery Mode persists with Settings and Log available | `testRecoveryModePersistsAndLeavesSettingsAndLogAvailable` | PASS |
| R100-07-A1a, empty-state guidance and accessible Main/Log controls | `testEmptyStateAndLogControlsExposeAccessibleDescriptions` | PASS |
| R100-07-A1b, Command-comma opens Settings | `testCommandCommaOpensSettingsFromMain` | PASS |
| R100-07-A1c, Delete removes collection association but preserves folder | `testDeleteRemovesSelectedCollectionButKeepsFolder` | PASS |
| R100-07-A1d1, Light and Dark selection persists across Settings reopen and relaunch | `testAppAppearanceSelectionPersistsAcrossWindowCloseAndRelaunch` | PASS |
| R100-07-A1d1, isolated preference-file behavior | `acceptanceAppearanceStoragePersistsWithoutReadingOrWritingUserDefaults` | PASS: `/private/tmp/mfp-r10007-appearance-storage-unit-final.log` |
| R100-07-A1d1, effective appearance across existing and reopened windows | `appearanceAndWindowReuseCoverEveryHostFlow` | PASS: `/private/tmp/mfp-r10007-coordinator-lifecycle-suite.log` |
| R100-07-A1d2-S1, status remains visible and Log controls work after reopen | `testCollectionStatusAndCoreWindowsRemainUsableAfterLogReopen` | PASS: `/private/tmp/mfp-r10007-point7-reopen-final2.log` |
| R100-07-A1d2-S2, Main remains usable after resize and original size is restored | `testCollectionStatusAndCoreWindowsRemainUsableAfterLogReopen` | PASS: `/private/tmp/mfp-r10007-point7-resize-accessibility-final.log`; Log resize remains unverified because macOS did not expose the utility window |
| R100-07-A1d2-S3, async history reload preserves keyboard search focus | `testLogAsyncSourceReloadKeepsKeyboardFocus` | PASS: `/private/tmp/mfp-r10007-point7-retry4.log` |
| R100-07-A1d2-S4, status and controls remain distinguishable with Increased Contrast | `testCollectionStatusAndControlsRemainUsableWithIncreasedContrast` | PASS: `/private/tmp/mfp-r10007-point7-high-contrast.log`; system setting restored |
| R100-07-A1d2-S5, VoiceOver announces search after async reload | `testVoiceOverSpeaksLogSearchAfterAsyncActivityReload` | PASS: `/private/tmp/mfp-r10007-point7-voiceover-restoration.log`; VoiceOver restored |
| R100-06-A1, cancel leaves saved access token unchanged | `testCanceledReplacementDoesNotValidateOrPersistCandidate` | PASS |
| R100-06-A1, valid confirmed replacement preserves collection/match after relaunch | `testValidReplacementIsConfirmedAndPreservesCollectionAndMatch` | PASS |
| R100-06-A2, invalid token is rejected safely and old token remains usable | `testRejectedReplacementPreservesExistingTokenAndRedactsCandidate` | PASS |
| R100-06-A2, offline state is distinct and candidate is not saved or shown | `testOfflineReplacementShowsSafeOutcomeWithoutSavingCandidate` | PASS |
| R110-05-A2, storage scope and capture time | `testLocalDataMeasurementAndPreviewInvalidation` | PASS |
| R110-05-A2, partial and unavailable estimates are not rendered as zero | `LocalDataPresentationTests/unavailableAndIncompleteEstimatesAreNotPresentedAsZero` | PASS: `/private/tmp/mfp-r11005-a2-final.log` (3-test Local Data presentation suite, 0 failures) |
| R110-03-A1-S1, combined category/severity/search shows only matching structured row | `structuredFiltersCombineAndControlsRemainKeyboardTraversable` | PASS: `/private/tmp/mfp-r11003-a1-final.log` |
| R110-03-A1-S2, nonmatching category/severity intersection shows no rows | `structuredFiltersCombineAndControlsRemainKeyboardTraversable` | PASS: `/private/tmp/mfp-r11003-a1-final.log` |
| R110-03-A1-S3, information severity and message search show the application row | `structuredFiltersCombineAndControlsRemainKeyboardTraversable` | PASS: `/private/tmp/mfp-r11003-a1-final.log` |
| R110-03-A1-S4, keyboard advances to Search and the Log key-view loop is configured | `structuredFiltersCombineAndControlsRemainKeyboardTraversable` | PASS: `/private/tmp/mfp-r11003-a1-final.log` |
| R110-03-A1-S5, Network source category/severity/search shows the matching request | `structuredFiltersCombineAndControlsRemainKeyboardTraversable` | PASS: `/private/tmp/mfp-r11003-a1-final.log` |
| R110-03-A2-S1, prior public event remains unchanged while new private settings event is redacted after relaunch | `testPrivateCollectionHistoryPersistsAcrossRelaunch` | PASS: `/private/tmp/mfp-r11003-a2-final.log` (1 XCUITest, 0 failures) |

### Acceptance status summary

The matrix contains 36 acceptance-criterion scenario groups: 28 PASS and 8
BLOCKED. It maps 57 distinct named automated test methods, all with passing
focused executions. The 60 matrix rows are coverage records; some rows group
multiple methods or scenarios, so row count is not a test count. Six coverage
records remain BLOCKED: cross-process Finder journeys for R100-04-A1/A2,
R100-08-A1, R110-02-A1, and R110-04-A1–A3, plus R100-09 release qualification.
There are no FAIL or NOT TESTED records. Acceptance remains incomplete until
the blocked Finder/signing and release prerequisites can be satisfied.

R110-03-A1 execution detail: the host AppKit acceptance test covers five
BDD scenarios; all five passed. The full-app Activity test passed, showing
only the matching Activity event after applying three filters. The five-test
`LogTableCoverageTests` suite passed with zero failures in
`/private/tmp/mfp-r11003-a1-final.log`. The Network-source scenario remains
covered by both the isolated AppKit/Network-history integration path and a new
full-app journey that seeds persisted Network events in disposable storage.
The full-app test filters the matching successful Movie Search row and verifies
the failed Poster Download row is absent. It does not make a live provider request.
Two initial executions failed in test setup: the first could not use the app
process's acceptance storage factory from the separate XCTest process, and the
second passed a mismatched path authorization root. The corrected helper uses
the same isolated storage paths with a test-host persistence factory. The final
focused execution passed in `/private/tmp/mfp-r11003-network-ui-final2.xcresult`.
The earlier Activity UI test's first run failed its `cells.count == 1` assertion:
NSTableView exposed
four accessibility cells for the single matching row. The corrected test
asserts the matching row's four visible columns and absence of the two
nonmatching seeded entries; the focused rerun passed. An intermediate
compile-only attempt using an unsupported `rows` property was corrected before
execution.
| R110-05-A3, preview invalidation | `testLocalDataMeasurementAndPreviewInvalidation` | PASS |
| R110-05-A1, native save and exact reviewed bytes | `testLocalDataMeasurementAndPreviewInvalidation` | PASS |

The native save panel result is in `/private/tmp/mfp-acceptance-publication.log`.
The Log severity filter and clearing of the hidden entry passed in
`/private/tmp/mfp-acceptance-log-filter.log`.
The additional saved outcome assertion passed in
`/private/tmp/mfp-acceptance-log-outcomes.log`.
R100-02-A2 full-app relaunch/details passed in
`/private/tmp/mfp-r10002-summary-final.log`.
R110-01-A1 passed in `/private/tmp/mfp-acceptance-rename.log`.
R110-03-A2 full-app persistence passed in `/private/tmp/mfp-acceptance-private.log`.
R100-03-A1 and R100-03-A3 full-app tests passed in
`/private/tmp/mfp-r10003-acceptance.log` (2 tests, 0 failures).
The expanded R100-03-A2 preservation test passed in
`/private/tmp/mfp-r10003-clear-expanded.log` (1 test, 0 failures).
R100-04-A3 host UI coverage passed in
`/private/tmp/mfp-r10004-recovery-ui.log` (1 test, 0 failures). A first run
failed because the test queried a nonexistent TMDb window title; the test now
closes the actual Settings window and the focused rerun passed.
The four R100-06 token replacement journeys passed in
`/private/tmp/mfp-r10006-token-ui-rerun.log` (4 tests, 0 failures). An initial
run exposed a stale Settings-window query in the shared test helper; the helper
now follows the actual TMDb window, and the focused rerun passed all four.
R100-07-A1d1 full-app Light/Dark persistence passed in
`/private/tmp/mfp-r10007-appearance-final.log` (1 test, 0 failures), verifying
the choice after Settings reopen and app relaunch and checking the isolated
preference file. The initial attempt queried the controls as Buttons; the
accessibility tree exposed them as CheckBoxes, and the corrected query passed.
The previously blocked appearance unit tests now execute after correcting
Swift 6 isolation mismatches in test fixtures. The focused Finder action suite
passed in `/private/tmp/mfp-acceptance-finder-action-compile-fix-retry3.log`;
the storage test passed in `/private/tmp/mfp-r10007-appearance-storage-unit-final.log`,
and the coordinator lifecycle suite (including effective appearance across
window reuse) passed in `/private/tmp/mfp-r10007-coordinator-lifecycle-suite.log`.
R100-07-A1a and A1b passed on the first focused run; A1c also passed, in
`/private/tmp/mfp-r10007-keyboard-ui.log` (3 tests, 1 failure caused by the
pre-existing search-field query). Correcting the query to use XCTest's
`searchFields` collection made A1a pass in
`/private/tmp/mfp-r10007-empty-accessibility-rerun.log` (1 test, 0 failures).
All three R100-07 scenarios therefore have passing final executions.

This file records scenario specifications and maps existing coverage. During
the acceptance phase, execute each listed automated test and update results
with actual output. A mapped unit/integration test is not a full-app E2E pass.
