# R120-04 Acceptance Tests

Issue: [R120-04, explicit identifiers and opt-in local information](https://github.com/AIBeCe/MovieFolderPosters/issues/18)

P1–P6 below refer to approved implementation points 1–6 in [R120-04_IMPLEMENTATION_PLAN.md](R120-04_IMPLEMENTATION_PLAN.md).
Core acceptance uses the real processor, disposable immediate movie folders, persistence, and real TMDb client with deterministic HTTP responses and a real icon adapter. Native Settings, Details, Unresolved Results, Retry Selected, and Choose Movie journeys require
full-app XCUITest. Parser, configuration, FileSystem, and Network component checks are supporting tests only.

## Isolation and deterministic fixtures

- UI tests use `MovieFolderPostersAcceptanceSupport` in `MovieFolderPosters/MovieFolderPostersUITests/`. Each creates a
  UUID directory under `/private/tmp/MovieFolderPostersAcceptance`, launches the Debug host with `--acceptance-test`,
  `--development-fixtures`, and `MOVIEFOLDER_ACCEPTANCE_TEST_ROOT`, and terminates the host before deleting the data.
- The Debug host redirects settings and processing state to `<root>/Shared`, validates the UUID child, and supplies a
  credential-free fixture token. Collections and movie files reside under this disposable root and use the real chooser.
- No live movie folders, real credentials, Finder registration/extension launch, or user icon mutation are required.
- Debug `StubTMDbTransport` supplies fixed `/3/movie/{id}` and `/3/find/{imdb-id}` fixtures, also tested through
  the real client by `identifierFixturesPassThroughRealClient` in
  `Packages/MovieFolderCommon/Tests/MovieFolderCommonTests/Development/StubTMDbTransportTests.swift`. Unknown routes
  fail closed and no request reaches TMDb.

### XCUITest runner signing and invocation

The host app must retain `MovieFolderPosters/Configuration/MovieFolderPostersAcceptance.entitlements`, which grants
the isolated host its test storage access. The `.xctest` bundle is ad-hoc signed with
`MovieFolderPostersUITests/Configuration/MovieFolderPostersUITests.entitlements`; the runner app is then ad-hoc
signed **without an entitlements argument**. Do not apply the runner's no-entitlements setting to the host target or
override the host's acceptance entitlements. From the Xcode project directory, the successful signing sequence is:

```sh
rtk codesign --force --sign - --timestamp=none \
  --entitlements MovieFolderPostersUITests/Configuration/MovieFolderPostersUITests.entitlements \
  /private/tmp/R120-04-AcceptanceScheme/Build/Products/Debug/MovieFolderPostersUITests-Runner.app/Contents/PlugIns/MovieFolderPostersUITests.xctest

rtk codesign --force --sign - --timestamp=none \
  /private/tmp/R120-04-AcceptanceScheme/Build/Products/Debug/MovieFolderPostersUITests-Runner.app
```

Verify the runner bundle signature with `rtk codesign --verify --deep --strict --verbose=2` before execution.
The successful test invocation used the generated `.xctestrun` with `xcodebuild test-without-building`,
`-destination platform=macOS,arch=arm64`, `-parallel-testing-enabled NO`, enabled test timeouts, and per-test
allowances of 240 seconds. It ran each approved `-only-testing` method into a fresh result bundle. The early run3
attempt failed before tests began with “Couldn’t communicate with a helper application”; after signing was corrected,
the later runner reached and executed UI tests. This infrastructure failure is retained in its log and is not a
scenario result. Retry UI helpers wait on the status element's accessibility label
`Collection results status`, find it through descendants, and observe its changing **value** for one of the exact
terminal messages (“Selected retries finished. Review saved results for individual outcomes.” or “Retries stopped.
Review the updated results before trying again.”). The terminal message precedes the one-time persisted-state read;
the test then verifies revision, assessment timestamp, identity, and outcome. Manual Apply waits for the exact
“Poster updated from TMDb movie 1.” message before closing the sheet. This avoids reading processing stores while
another process may still be writing them.

## Scenario matrix

| ID | Given | When | Then | Requirement | Automated coverage and surface |
| --- | --- | --- | --- | --- | --- |
| AT01 | Fresh settings. | Open Matching Defaults, inspect defaults, save each of 8 switch combinations, relaunch. | All sources default off; every combination persists independently. | P2: default-off global options. | Full-app `testLocalInformationDefaultsAreOff`, `testGlobalLocalInformationOptionsPersistAcrossRelaunch` in `MovieFolderPosters/MovieFolderPostersUITests/R12004LocalInformationUITests.swift`; supporting component `localInformationConfigurationDefaultsAndRoundTrips` in `Packages/MovieFolderCommon/Tests/MovieFolderCommonTests/Configuration/LocalInformationConfigurationTests.swift`. |
| AT02 | Global switches have mixed values. | Create an inheriting collection, save a distinct override, cancel an edit, relaunch/reopen. | Inherited/effective values display correctly; override persists independently; Cancel discards edits. | P2: inheritance, override, cancellation. | Full-app `testCollectionInheritanceOverrideAndCancelPersistAcrossRelaunch` in `MovieFolderPosters/MovieFolderPostersUITests/R12004LocalInformationUITests.swift`. |
| AT03 | Collection has saved outcomes. | Change local-source options without visiting/retrying it. | No processing run is synthesized; saved outcomes remain until an authorized invocation. | P2/P4: passive source-only settings. | Full-app `testChangingLocalInformationOptionsDoesNotStartCollectionProcessing` in the UI test file. |
| AT04 | Folder has valid TMDb, IMDb, or combined labels; deterministic direct records exist. | Retry the selected folder. | Direct lookup resolves one identity; poster/provenance are saved; identical repeats collapse through actual host provider composition. | P1: labelled IDs and direct provider lookup. | Common processor `at04LabelledIdentifiersEstablishOneOwnedPoster` and host-composition `at04HostProviderCompositionResolvesSelectedIdentifiers`, `Packages/MovieFolderCommon/Tests/MovieFolderCommonTests/Processing/R12004LocalInformationAcceptanceTests.swift`; full-app `testRetrySelectedMatchesValidatedIdentifiersAndShowsProvenance` and diagnostic `testIMDbOnlyIdentifierAsIndependentJourney` in UI test file. |
| AT05 | Folder contains malformed, zero, overflow, overlong, or suffix-junk recognized IDs. | Process/retry it. | Invalid labels do not truncate to valid identities or permit weaker fallback. | P1: bounded parsing and fail-closed behavior. | Common `at05UnusableIdentifiersNeverFallBack` in `R12004LocalInformationAcceptanceTests.swift`; supporting parser `labelledIdentifierParsingRejectsInvalidInformation` in `.../Processing/MovieIdentifierInformationTests.swift`. |
| AT06 | Recognized ID receives missing, malformed, contradictory, failed, or credential-rejected provider response. | Automatic processing handles it. | No title fallback/assignment occurs; applicable unresolved/recovery/conflict state is retained. | P1: provider validation and failure handling. | Common `at06ProviderFailuresPreserveRecoveryAndNeverFallBack`; Network tests are supporting contract checks only. |
| AT07 | Disposable folder has usable NFO, video-name, and image-name identity. | Retry with each source independently enabled and disabled. | Only enabled sources contribute. | P2/P3: independent opt-in gates. | Common `at07SourceGatesAreIndependent`; full-app `testRetrySelectedUsesEnabledNFOInformation`, `testRetrySelectedUsesEnabledVideoNameInformation`, `testRetrySelectedUsesEnabledImageNameInformation` in `MovieFolderPosters/MovieFolderPostersUITests/R12004LocalInformationUITests.swift`. |
| AT08 | NFO, video, image, and folder contain distinct titles/years. | Process with sources enabled. | Highest complete rank wins: NFO > video > image > folder, independent of enumeration. | P3: precedence and uniqueness. | Common `at08HighestCompleteSourceWins`; resolver tests are supporting only. |
| AT09 | Multiple same-rank filenames agree, or valid IDs/equally ranked names conflict. | Process and inspect the saved result/retry availability. | Consistent same-rank evidence establishes the movie; contradictory identities stay manual without an automatic retry loop. | P1/P3/P5: consistency, conflict decisions. | Common `at09ConsistentSameRankFilesEstablishOneMovie` and `at09ContradictionsRemainManualWithoutRetryLoop`; full-app manual selection is AT21. |
| AT10 | Immediate movie-root NFO has supported title/original title/year/IDs. | Enable NFO and process. | Valid NFO drives matching with NFO provenance. | P3/P6: supported NFO information. | Common `at10NFOFieldsAndEncodingEstablishMovie`; full-app NFO journey in UI test file. |
| AT11 | NFO has unsafe DTD/entity/external resource, malformed XML, wrong root, contradictory fields, or malformed year/ID. | Enable NFO and process. | No unsafe/partial identity and no external resource fetch. | P6: XML safety. | Common `at11UnsafeNFOCannotEstablishPartialIdentity`, `at11XMLNeverFetchesExternalResources`; parser tests are supporting only. |
| AT12 | Folder contains hidden/visible immediate files, nested entries, a symlink to a valid NFO elsewhere in the disposable test root, nonregular or replaced entries. | Enable reading and process. | Supported immediate regular hidden/visible files may contribute; nested files do not; symlink targets outside the movie child, replacement, or incomplete capture fail closed. | P3/P6: inventory scope and filesystem safety. | Common `at12OnlyImmediateRegularSupportedInformationContributes`; FileSystem tests are supporting service checks. |
| AT13 | Entry count, NFO count, per-file bytes, aggregate bytes are at and one over each cap. | Capture/process boundary fixtures. | Inclusive limits pass; over-limit information is incomplete and cannot establish partial unique identity. | P6: exact budgets. | Common `at13InclusiveBudgetsRejectPartialUniqueness`; FileSystem boundary tests are supporting checks. |
| AT14 | Immediate filenames use supported/unsupported extensions or generic stems. | Enable filename reads and process. | Supported extensions match case-insensitively; unsupported/generic names establish no identity. | P6: extensions and conservative parsing. | Common `at14EverySupportedExtensionUsesItsFilename`, `at14GenericNamesCannotEstablishIdentity`. |
| AT15 | Local names establish identity; local artwork contains marker bytes. | Process and inspect assigned artwork and original contents. | Provider artwork is used; local image bytes are neither selected nor modified. | P3: no artwork selection/content writes. | Common `at15ProviderArtworkIsUsedWithoutChangingMovieContents`; UI image journey checks unchanged bytes. |
| AT16 | An unresolved result and local-information digest are saved. | Revisit with unchanged input, then changed input. | Unchanged input retains the result without duplicate provider work; changed input allows reassessment. | P4: digest freshness. | Common `at16ChangedUnresolvedInformationReassessesAfterReopen`; UI Retry Selected is separately AT20, not an ordinary visit. |
| AT17 | Local information changes during provider wait or final assignment admission. | Resume the gated operation. | Stale identity is discarded and not assigned or cached. | P3/P4: in-flight and final freshness fences. | Common `at17ProviderWaitChangesDiscardStaleAttempts`, `at17FinalFenceAndReplacementPreventAssignment`, deterministic gates. |
| AT18 | Processing is active and cancellation is requested. | Cancel and later invoke again. | No partial/negative identity is saved; later eligible processing can resume. | P3/P4: cancellation/recovery. | Common `at18CancellationDoesNotSaveNegativeIdentityAndCanResume`, cancellation gate. |
| AT19 | Confirmed/explicit movie and poster exist; local information changes. | Revisit through processing or relaunch the host without a new explicit selection. | Confirmed/explicit identity and installed poster remain protected. | P4: saved decisions and poster ownership. | Common `at19ConfirmedAndExplicitPostersSurviveInformationChanges`; UI preserve/reopen check is in `testConflictGuidanceLeadsToAuthoritativeManualSelection`; no Finder icon mutation. |
| AT20 | Unresolved/fresh folder is eligible for action. | Retry only selected row or invoke fresh refresh with current/changed input. | Requested member is revalidated; unrelated records remain intact. | P4/P5: selected retry and refresh. | Common `at20SelectedRetryUsesCurrentInformationAndFreshRefreshIsProtected`; full-app `testRetrySelectedReassessesChangedLocalInformation`. |
| AT21 | A match or conflict is saved. | Open Details/Unresolved Results; for conflict choose/apply a movie. | Correct provenance or exact manual guidance appears; explicit selection resolves and persists. | P5: provenance and manual resolution. | Full-app ID/NFO/video/image provenance journeys plus `testConflictGuidanceLeadsToAuthoritativeManualSelection`; Common `at09ContradictionsRemainManualWithoutRetryLoop`. |
| AT22 | Prior-schema settings/outcomes/cache and an NFO with unique raw marker exist. | Migrate and save/reopen state. | New options migrate false, previous choices/outcomes remain, raw NFO bytes are absent from persisted records. | P2/P4: migration and privacy. | Common `at22MigrationPreservesFactsAndAdoptsLegacyIdentifiers` and privacy checks in `at16ChangedUnresolvedInformationReassessesAfterReopen`; existing `LocalInformationConfigurationTests.swift` migration checks are supporting evidence. |

### Stable parameterized examples

These example IDs identify the input variants exercised by the parameterized acceptance methods. Each example
uses its parent AT requirement and expected outcome above; method-level execution status is recorded separately
in the Acceptance Report.

| Example IDs | Input variants |
| --- | --- |
| AT01.01–AT01.08 | All eight Boolean combinations of NFO, video-name, and image-name global settings, including all-off. |
| AT04.01–AT04.07 | `[tmdb:348]`, `[tmdb-348]`, `[TMDB348]`, `[imdb:tt0078748]`, `[tt0078748]`, combined TMDb+IMDb, repeated identical TMDb in the core processor. |
| AT04.08–AT04.10 | Actual host selected-retry composition with TMDb-only, IMDb-only, and combined TMDb+IMDb identifiers; standalone IMDb-only journey isolates the failing UI variant. |
| AT05.01–AT05.12 | Zero, negative, Int32 overflow, very large integer, too-short/zero/too-long IMDb syntax, numeric/text suffix junk, malformed recognized label, two distinct TMDb labels. |
| AT06.01–AT06.08 | Missing, non-movie, ambiguous, malformed, mismatched, authentication, rate-limited, and offline provider responses. |
| AT07.01–AT07.06 | NFO/video/image source × disabled/enabled. |
| AT08.01–AT08.10 | Five precedence ranks (identifier, NFO, video, image, folder) × normal/reversed file-creation order. |
| AT09.01–AT09.05 | Conflicting video names, image names, two NFOs, folder-vs-NFO IDs, provider disagreement. |
| AT09.06–AT09.08 | Consistent same-rank NFO, video, and image files, each establishing one movie. |
| AT10.01–AT10.08 | NFO title/originaltitle/TMDb/IMDb identity × UTF-8/UTF-16 encoding. |
| AT11.01–AT11.12 | Empty/truncated XML, wrong root, malformed/zero year, ID suffix junk, repeated conflicting title/year/ID, DTD, internal entity, external DTD; a loopback sentinel separately proves external resource fetch is not attempted. |
| AT12.01–AT12.05 | Nested supported file, unsupported file, symlink, FIFO, hidden immediate supported file. |
| AT13.01–AT13.08 | Entry count, NFO count, per-file bytes, aggregate bytes × at-limit/over-limit. |
| AT14.01–AT14.17 | Each of 17 approved case-insensitive video/image extensions; generic stems are separately AT14.18–AT14.23 for poster, cover, folder, fanart, sample, trailer. |
| AT17.01–AT17.04 | Mutation while `/search/movie`, `/alternative_titles`, `/release_dates`, or poster `/w500/fixture.png` response is held. |
| AT17.05–AT17.06 | Final assignment fence with in-place information mutation or folder replacement. |
| AT19.01–AT19.02 | Confirmed automatic identity and explicit identity with information changed. |
| AT20.01–AT20.03 | Selected retry, fresh refresh with current information, fresh refresh with changed information. |

Component tests remain supporting checks. Full-app E2E is required for settings, provenance/details, conflict/manual
resolution, and selected retry. A source harness, view-model test, successful build, or component pass is not a full-app
journey or a PASS for an unexecuted scenario.

## Execution status

All 22 scenarios are specified. See [R120-04_ACCEPTANCE_REPORT.md](R120-04_ACCEPTANCE_REPORT.md) for individual
statuses. Scenarios remain NOT TESTED until their approved behavioral/UI tests actually execute and evidence is reviewed.
