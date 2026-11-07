# R120-04 Acceptance Report

Issue: [R120-04, explicit identifiers and opt-in local information](https://github.com/AIBeCe/MovieFolderPosters/issues/18)

Scenario BDD definitions and requirement mappings are in [R120-04_ACCEPTANCE_TESTS.md](R120-04_ACCEPTANCE_TESTS.md).
This report preserves each executed result. The direct-identifier UI journey was rerun after fixing transient
configuration-lock handling and now passes. Acceptance Testing remains incomplete pending the separate diagnostic
method and phase review.

## Execution summary

| Status | Scenarios | New acceptance/UI test methods |
| --- | ---: | ---: |
| PASS | 22 | 32 |
| FAIL | 0 | 0 |
| BLOCKED | 0 | 0 |
| NOT TESTED | 0 | 1 |

**Overall: INCOMPLETE.** AT04 now passes for IMDb-only, combined, and repeated identifiers. AT21's conflict/manual and
source-provenance journeys passed in run9; the standalone AT04 diagnostic remains NOT TESTED.

New Common processor acceptance: 23 test declarations passed. Base run: 20 declarations, 0 failures, 26.566 seconds,
`/private/tmp/R120-04-acceptance-common-final.log`; review reruns for updated AT08, AT16, and AT20 passed in
`/private/tmp/R120-04-acceptance-common-review.log`; the AT11 external-resource sentinel passed separately in
`/private/tmp/R120-04-acceptance-xml-sentinel.log` after the sandbox blocked the first attempt. The additional
host-composition selected-identifier method passed all three variants in
`/private/tmp/R120-04-acceptance-host-identifiers2.log`; its initial fixture setup failure remains preserved in
`/private/tmp/R120-04-acceptance-host-identifiers.log`. Debug fixture client coverage passed both variants in
`/private/tmp/R120-04-acceptance-debug-identifiers.log`. Same-rank consistency coverage added
`at09ConsistentSameRankFilesEstablishOneMovie`; all three NFO/video/image variants passed in
`/private/tmp/R120-04-acceptance-consistent-files.log`. Existing Common regression selection: 31 tests passed in
`/private/tmp/R120-04-acceptance-existing-common.log`. Existing FileSystem
support selection: 3 declarations passed, including five NFO budget examples and two replacement cases, in
`/private/tmp/R120-04-acceptance-existing-filesystem2.log`.

New full-app UI suite latest observed outcomes: 10 PASS, 0 FAIL, 1 NOT TESTED across 11 declarations. The initial six-method attempt is in
`/private/tmp/R120-04-acceptance-ui-run4.log` and `/private/tmp/R120-04-acceptance-ui-run4.xcresult`. Defaults,
global 8-combination persistence, collection inheritance/override/cancel, passive settings change, NFO/image/video
source, and changed-input selected retry passed. The changed-input retry also passed in isolation in run8
(`/private/tmp/R120-04-acceptance-ui-run8.log`, 59.229 seconds, 1 test, 0 failures). The identifier journey initially failed
for the IMDb-only fixture with a saved “Movie metadata could not be read” result. Conflict/manual runs6 and 7 both
failed only at the final retry-completion predicate. Run6's user-visible manual Apply, persisted identity/source,
owned icon, relaunch, and Details assertions passed before that predicate failure; run7 repeated the predicate failure
and was stopped before the remaining methods. Root corrected the predicate to read the status element's `value`
using its explicit accessibility label, and moved the persisted-state read after a terminal status. The conflict/
manual journey passed in run9 in 93.177 seconds (`/private/tmp/R120-04-acceptance-ui-run9.log` and matching xcresult),
including Apply, relaunch, persisted identity/provenance, and owned-icon assertions. The same method had earlier
failed in runs4/6/7; those failed attempts remain recorded. The run9 identifier method then failed for its IMDb-only
variant after TMDb-only, combined-ID, and repeated-ID variants passed. NFO, video, and image UI journeys passed in
run9 (68.984, 83.193, and 79.482 seconds). A standalone `testIMDbOnlyIdentifierAsIndependentJourney` was added to
isolate the IMDb-only behavior; it is NOT TESTED pending build/execution. The failure was traced to transient
`ConfigurationError.busy` at the post-provider authorization fence. Selected retry now briefly waits and revalidates
the fence while retaining the provider result. The focused processor regression passed, and the direct-identifier
UI method passed all three variants in 143.850 seconds (`/private/tmp/R120-04-acceptance-ui-final-rerun.xcresult`).
The earlier failed attempt remains recorded in `/private/tmp/R120-04-acceptance-ui-fixed-run15.log`.

Runner history: UI run3 failed before tests started with “Couldn’t communicate with a helper application”; the later
run4 runner was signed ad hoc without an entitlements file, while the host target retained its acceptance entitlements.
This startup failure is an environment/setup attempt, not a scenario result. Run4 successfully launched and produced
the test outcomes above. The next run is being rebuilt with fixed completion waits and helper interactions.

Counts above include the 23 new Common declarations and 11 new UI methods. The Debug transport's real-client method
(`identifierFixturesPassThroughRealClient`, 2 variants), 31 pre-existing Common regressions, and
3 FileSystem support declarations are reported separately as supporting checks, not counted as R120-04 acceptance
methods. Parameterized examples are enumerated in the acceptance specification; method counts are declaration counts.

## Individual scenario results

| ID | BDD and requirement | Test mapping and method results | Execution surface | Expected | Actual observed | Scenario status and evidence |
| --- | --- | --- | --- | --- | --- | --- |
| AT01 | Given fresh settings, when defaults are inspected and all 8 global combinations are saved/relaunched, then all options default off and each combination persists independently. P2. | `testLocalInformationDefaultsAreOff` PASS; `testGlobalLocalInformationOptionsPersistAcrossRelaunch` PASS; `MovieFolderPosters/MovieFolderPostersUITests/R12004LocalInformationUITests.swift`. | Full-app isolated Debug host. | Off defaults and saved combinations survive relaunch. | Both methods passed in the UI run. | PASS; run4 log/xcresult. |
| AT02 | Given mixed global values, when collection inheritance, override, cancellation, and relaunch are exercised, then effective settings and override persist and Cancel discards edits. P2. | `testCollectionInheritanceOverrideAndCancelPersistAcrossRelaunch` PASS; UI test file. | Full-app isolated host and temporary collection. | Correct inheritance, independent override, cancellation. | Method passed in the UI run. | PASS; run4 log/xcresult. |
| AT03 | Given saved outcomes, when local-source options change without collection visit, then no run/outcome is synthesized. P2/P4. | `testChangingLocalInformationOptionsDoesNotStartCollectionProcessing` PASS; UI test file. | Full-app isolated host and store. | No processing until authorized invocation. | Method passed in the UI run. | PASS; run4 log/xcresult. |
| AT04 | Given valid TMDb/IMDb/combined identifiers, when selected retry runs, then direct resolution assigns one reconciled movie and validated-ID provenance; repeated IDs collapse. P1. | Common `at04LabelledIdentifiersEstablishOneOwnedPoster` PASS; host composition `at04HostProviderCompositionResolvesSelectedIdentifiers` PASS; UI `testRetrySelectedMatchesValidatedIdentifiersAndShowsProvenance` PASS; `testIMDbOnlyIdentifierAsIndependentJourney` NOT TESTED. | Real processor, actual host provider composition, and full-app retry. | Correct identity/provenance for TMDb, IMDb, combined IDs without weaker search. | All three UI variants passed after selected retry began retrying transient configuration-lock contention at the post-provider authorization fence. | PASS; `/private/tmp/R120-04-acceptance-ui-final-rerun.xcresult`. Diagnostic method is NOT TESTED. |
| AT05 | Given malformed/zero/overflow/overlong/suffix-junk IDs, when processed, then invalid labels do not truncate or permit fallback. P1. | Common `at05UnusableIdentifiersNeverFallBack` PASS; supporting parser test `labelledIdentifierParsingRejectsInvalidInformation`. | Real processor and disposable filesystem. | No identity assignment or weaker search. | Processor acceptance passed across the parameterized invalid labels. | PASS; Common base log. |
| AT06 | Given missing/malformed/disagreeing/provider-failed/credential-rejected ID responses, when processed, then no fallback occurs and recovery/conflict state is retained. P1. | Common `at06ProviderFailuresPreserveRecoveryAndNeverFallBack` PASS. | Real processor and deterministic HTTP transport. | No automatic fallback; correct recoverable state. | Processor acceptance passed across all response modes. | PASS; Common base log. |
| AT07 | Given usable local sources, when each option is enabled/disabled independently, then only enabled sources contribute. P2/P3. | Common `at07SourceGatesAreIndependent` PASS; UI NFO/video/image tests PASS. | Real processor and full-app retry UI. | Source-specific enabled/disabled behavior. | Common acceptance passed; NFO/video/image UI completed in 68.984/83.193/79.482 s. | PASS; Common base and UI run9 logs/xcresult. |
| AT08 | Given distinct titles across NFO/video/image/folder, when processed, then highest complete source wins regardless of file creation order. P3. | Common `at08HighestCompleteSourceWins` PASS (normal and reversed creation). | Real processor and disposable filesystem. | NFO > video > image > folder. | Both order variants passed in the Common base run; updated review rerun also passed. | PASS; Common base and review logs. |
| AT09 | Given consistent or contradictory same-rank names/IDs, when processed, then agreement resolves one identity and conflict remains manual without retry loop. P1/P3/P5. | Common `at09ConsistentSameRankFilesEstablishOneMovie` PASS; `at09ContradictionsRemainManualWithoutRetryLoop` PASS. Full-app conflict manual path is AT21. | Real processor, persistence, isolated fixture. | Consistent NFO/video/image files resolve; contradictory evidence remains unresolved/manual. | Three consistency variants and all conflict variants passed. | PASS; `/private/tmp/R120-04-acceptance-consistent-files.log` and Common base log. |
| AT10 | Given a valid movie-root NFO, when enabled and processed, then supported fields/encoding establish the expected identity. P3/P6. | Common `at10NFOFieldsAndEncodingEstablishMovie` PASS. | Real processor and disposable NFO. | Correct movie and NFO or validated-ID provenance. | All field/encoding examples passed. | PASS; Common base log. |
| AT11 | Given unsafe/malformed/wrong-root/contradictory NFO, when enabled and processed, then no partial identity or external fetch occurs. P6. | Common `at11UnsafeNFOCannotEstablishPartialIdentity` PASS; `at11XMLNeverFetchesExternalResources` PASS. | Real processor, disposable XML, loopback-only sentinel. | No partial assignment and no attempted external entity resource read. | Malformed cases passed; positive-control loopback sentinel confirmed the parser did not request the sentinel resource. | PASS; Common base log and `/private/tmp/R120-04-acceptance-xml-sentinel.log`. |
| AT12 | Given hidden/visible immediate entries plus nested entries, a symlink to a valid NFO outside the movie child, unsafe entries, and replacements, when processed, then only eligible immediate regular files contribute. P3/P6. | Common `at12OnlyImmediateRegularSupportedInformationContributes` PASS; supporting FileSystem replacement/capture selection PASS. | Real processor/filesystem; disposable root. | Hidden immediate supported file accepted; nested/link-to-outside-child/nonregular/replaced entries rejected safely. | All five processor variants passed; the symlink pointed to a valid NFO elsewhere under the disposable root and was rejected. | PASS; Common base and `/private/tmp/R120-04-acceptance-symlink.log`; FileSystem support log. |
| AT13 | Given each inventory/NFO budget at and over its limit, when captured, then maxima are accepted and overages cannot produce partial unique matches. P6. | Common `at13InclusiveBudgetsRejectPartialUniqueness` PASS; supporting FileSystem budget examples PASS. | Real processor and generated boundary fixtures. | Inclusive limits and fail-closed overages. | Processor and supporting FileSystem budget cases passed. | PASS; Common base and FileSystem support logs. |
| AT14 | Given supported/unsupported extensions and generic filename stems, when enabled and processed, then only approved formats/useful names contribute. P6. | Common `at14EverySupportedExtensionUsesItsFilename`, `at14GenericNamesCannotEstablishIdentity` PASS. | Real processor/filesystem. | All 17 extensions accepted case-insensitively; six generic names ignored. | All parameterized extension and generic-name examples passed. | PASS; Common base log. |
| AT15 | Given useful filenames and local artwork marker bytes, when processed, then provider artwork is used and local movie contents remain unchanged. P3. | Common `at15ProviderArtworkIsUsedWithoutChangingMovieContents` PASS. Full-app image-name UI journey PASS under AT07. | Real processor/icon adapter and isolated files. | Local image/video bytes are not used as poster or modified. | Common processor verified provider poster assignment and unchanged local bytes; UI image journey passed in run9 in 79.482 s. | PASS; Common base and UI run9 logs/xcresult. |
| AT16 | Given a saved unresolved result/digest, when later input is unchanged and then changed, then unchanged input is retained and changed input permits reassessment. P4. | Common `at16ChangedUnresolvedInformationReassessesAfterReopen` PASS. | Real processor and persisted operational/outcome stores. | No duplicate provider work for unchanged data; new assessment after change. | Test passed; review version also verified settings/outcome/operational persistence excludes unique raw NFO marker. | PASS; Common base and review logs. |
| AT17 | Given local information changes during provider waits or final admission, when operations resume, then stale identity is never assigned/cached. P3/P4. | Common `at17ProviderWaitChangesDiscardStaleAttempts`, `at17FinalFenceAndReplacementPreventAssignment` PASS. | Gated processor integration and real disposable filesystem/icon adapter. | No stale assignment across search, metadata, artwork, final fence, or replacement. | All gated provider stages and final mutation/replacement variants passed. | PASS; Common base log. |
| AT18 | Given active processing, when cancellation occurs and a later authorized invocation follows, then no partial negative identity is saved and processing can resume. P3/P4. | Common `at18CancellationDoesNotSaveNegativeIdentityAndCanResume` PASS. | Gated real processor. | Cancellation is atomic; later processing succeeds from current information. | Cancellation and resume assertions passed. | PASS; Common base log. |
| AT19 | Given confirmed/explicit identity and poster, when information changes and state is revisited, then the saved identity/poster remain protected. P4. | Common `at19ConfirmedAndExplicitPostersSurviveInformationChanges` PASS; UI preservation assertions are within `testConflictGuidanceLeadsToAuthoritativeManualSelection`. | Real processor/icon adapter; full-app persisted state. | No replacement from local changes alone. | Processor preservation passed. Full-app Apply, persisted identity/source, owned icon, relaunch, and Details assertions passed in run9 after the terminal-status wait was corrected. | PASS; Common base and `/private/tmp/R120-04-acceptance-ui-run9.log` plus matching xcresult. Earlier run6/7 predicate failures are preserved in history. |
| AT20 | Given an eligible unresolved/fresh folder, when selected retry or current/changed fresh refresh runs, then only the requested member is revalidated and unrelated outcomes remain. P4/P5. | Common `at20SelectedRetryUsesCurrentInformationAndFreshRefreshIsProtected` PASS (selected/current refresh/changed refresh); UI `testRetrySelectedReassessesChangedLocalInformation` PASS. | Processor acceptance and native unresolved-results sheet. | Current captured information used; unrelated folders preserved. | Common three operation modes passed; isolated UI selected-retry passed in run4 (51.7 s) and run8 (59.229 s). | PASS; Common base/review and UI run4/run8 logs and xcresults. |
| AT21 | Given saved match/conflict, when Details/Unresolved Results are opened and a movie is chosen/applied, then provenance/guidance appears and manual choice persists. P5. | `testConflictGuidanceLeadsToAuthoritativeManualSelection` PASS; UI identifier provenance is separately reported under AT04; NFO/video/image source journeys PASS. | Native isolated host UI and deterministic fixtures. | Correct source/guidance; manual selection resolves and persists. | Conflict/manual flow passed in 93.177 s, including Apply, relaunch, saved provenance/icon and Details. NFO/video/image source journeys also passed in run9. | PASS; `/private/tmp/R120-04-acceptance-ui-run9.log` and matching xcresult. |
| AT22 | Given prior-schema stores and a unique NFO marker, when migration and reopen occur, then old facts remain, new options default false, and raw NFO is absent from persistence. P2/P4. | Common `at22MigrationPreservesFactsAndAdoptsLegacyIdentifiers` PASS; existing migration selection also passed. Privacy assertion is additionally in AT16. | Real storage migration and processor persistence. | Existing outcomes preserved, options migrated, no raw source bytes saved. | New Common scenario and 31-test existing regression selection passed; AT16 verified raw marker absence in relevant stores. | PASS; Common base/review and existing Common regression logs. |

## Supporting checks and remaining work

- Existing Common regression selection: 31 PASS. Existing FileSystem support selection: 3 declarations PASS,
  including five NFO budget examples and two replacement examples. These support AT12/AT13 but are not counted as
  the 23 new processor acceptance declarations.
- Existing UI helper regressions also passed after the collection fixture explicitly configured its required
  `pt-BR` baseline: spelling suggestion, 37.472 seconds (run6), and saved search language, 49.126 seconds (run7).
  Their original saved-language fixture failure is preserved in run6; the corrected test restores an explicit
  language assertion rather than weakening it. These checks are not R120-04 scenario methods.
- Full-app collected run: initial run4 had 8 PASS and 2 FAIL; later reruns fixed shared UI wait issues. Current
  R120-04 UI method outcomes are 10 PASS, 0 FAIL, and 1 NOT TESTED. AT01–AT04 passed; AT07 source journeys and
  AT20 changed-input retry passed. AT21's conflict/manual and source journeys passed. The separate AT04 diagnostic
  `testIMDbOnlyIdentifierAsIndependentJourney` remains NOT TESTED.
- Finder registration, extension runtime, and persistent Finder icon qualification were not performed or required.
