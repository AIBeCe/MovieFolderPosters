# R120-02 — Year, edition, and spelling evidence

Status: Three approved points implemented; independent review PASS; awaiting completed Implementation Phase approval.
Branch: `feature/year-edition-spelling`, based on `develop` at `53a3908`.
Issue: https://github.com/AIBeCe/MovieFolderPosters/issues/16

## Goal and architecture

Extend conservative identification without treating numeric proximity or spelling similarity as identity.
Keep Foundation-only edition parsing in MovieFolderParsing, provider transport in Network, matching and
processing in MovieFolderCommon, and presentation-only spelling suggestions in the AppKit PosterActions feature.
The approved proposal in this chat is the specification; this document preserves its decisions and execution state.

## Binding constraints and approvals

- All three points were individually approved; the complete proposal was approved before implementation.
- Implement points sequentially. No commit until completed Implementation Phase approval.
- Formal Validation and Acceptance Testing require separate explicit authorization. No SwiftLint in implementation.
- Preserve Swift 6, programmatic AppKit, configured deployment floor, existing modules and movie contents.
- Preserve unrelated Xcode user data and MovieFolderParsing `.swiftpm` files.
- No live credentials, TMDb requests, Finder registration, real movie folders, or live icon changes for checks.
- No new dependencies, services, pagination, or persisted spelling corrections.

## Point 1 — Edition suffixes

- [x] Add bounded phrases after a release year: director's/directors cut, collector's/collectors edition,
  special edition, final cut, theatrical cut. Accept case and curly-apostrophe variants.
- [x] Require a complete phrase followed only by existing technical tags; preserve title words and conflicting years.
- [x] Advance parser revision to 3; expose `hasRecognizedEditionSuffix(_:)` and extend targeted unresolved recovery.
- [x] Add parser and processor recovery regressions, observe RED then GREEN with focused checks.

Files: `Packages/MovieFolderParsing/Sources/MovieFolderParsing/ReleaseNameParser.swift`, its tests,
`MovieFolderProcessor+AutomaticMatching.swift`, and `MovieFolderProcessorRecoveryEligibilityTests.swift`.

## Point 2 — Provider-backed release years

- [x] Add `MovieYear` (year: Int, type: MovieYearType); types primaryRelease, premiere, limitedTheatrical,
  theatrical, digital, physical, television. A movie can have multiple year values. Derive event years from dates.
- [x] Add validated, movie-ID-keyed release-date retrieval in Network, request observation and recovery forwarding.
  Preserve country, exact timestamp, and type; successful empty evidence differs from malformed/failed evidence.
- [x] Automatic and fresh conservative Refresh discovery uses title/language without a year filter. Preserve parsed
  year for matching. Assess primary years within +/-1, including unknown-primary candidates as uncertainty.
- [x] Apply five-ID budget before details; complete alias comparison before release-year qualification. Only exact
  title-compatible nearby candidates need release-date requests. Unknown-primary exact titles prevent assignment.
- [x] Exact primary year qualifies directly. A different year requires both years in provider premiere/limited/
  theatrical events for that same ID. Digital/physical/TV events and fuzzy titles cannot authorize matching.
- [x] Choose a unique identity only after qualification; exact-year and corroborated nearby candidates compete.
  Incomplete pagination or failed evidence cannot yield assignment. Maximum 11 metadata requests per matching run.
- [x] Preserve confirmed-ID refusal, authorization, fingerprint, suppression and ownership gates after awaits.
- [x] Retain optional accepted release events with automatic identity through refresh/repair/failure rewrites;
  clear when an explicit selection supersedes them. Keep primary provider year separate from folder year.
  Use approved MovieYear vocabulary rather than the superseded MovieYearEvidence/MovieYearAssessment names.
- [x] Add a matching-rules version; reconsider eligible older unresolved automatic noSuitableMovie/
  ambiguousMovie decisions once during normal processing. Do not reopen processed or explicit-selection decisions.
- [x] Backward-compatible optional record fields; no new store or release-date response cache.
- [x] Focused transport, matcher, processor, recovery and compatibility RED/GREEN checks; update directly affected
  provider conformances and deterministic fixtures.

Files: Network models/client/observation/tests; Common matcher, metadata enrichment, contracts, recovery,
automatic/manual processing, cache records and rewrites, network-history label and focused tests; host missing-token
provider and directly affected test providers. Use cohesive source extensions when needed, without changing ownership.

## Point 3 — Explicit spelling suggestions

- [x] Add host-only `MovieTitleSpellingDifferenceChecker` using the approved one-word/one-edit heuristic, min word length 4,
  no numeric differences, max title 256 Unicode scalars and word 64 characters, case/accent/punctuation normalization.
- [x] Use localized/original titles returned by the explicit search; label possible differences, preserve order,
  never preselect, alter query, apply, generate requests or persist corrections. No result means no suggestion.
- [x] Capture submitted title; changed title/year invalidates result, suggestion and selection. Cancellation and
  configuration changes must not publish stale results.
- [x] Existing picker labels possible spelling differences; selected status explains query -> suggested title;
  wrap status and add accessible picker label. Keep existing native hierarchy and Light/Dark semantic appearance.
- [x] Add focused spelling and view-model action/state regressions; check fuzzy-only automatic refusal in Common.

Files: new `MovieTitleSpellingDifferenceChecker.swift`, `MoviePosterActionViewModel.swift`,
`MoviePosterActionCoordinator.swift`, and mirrored host tests.

## Review focus and checks

Independent review must cover unsupported nearby candidates versus true ambiguity, unknown years, incomplete alias/
date evidence, request limits, date validation/timezones, cache context, stable old outcomes, retained provenance,
confirmed identity and stale manual suggestions. Focused tests use disposable storage and deterministic providers.
Run only issue-relevant checks, not the full project suite. Record exact commands/results/log paths below.
Inspect an unsigned native build for compilation coherence; it does not establish rendered UI or Finder behavior.

## Execution evidence and remaining work

- Baseline: only unrelated untracked Xcode user data and parser SwiftPM state; no tracked edits.
- Point 1 focused RED: parser behavior run against a temporary HEAD copy failed all 9 complete-edition parse cases;
  recovery test failed to reconsider the old unresolved edition folder (no fresh search or assignment).
- Point 1 focused GREEN: `scripts/test-parser.sh` passed all 13 parser tests; the MovieFolderCommon filter for
  `cachedEditionSuffixDecisionIsReassessedOnce`, `cachedIdentifierSuffixDecisionsAreReassessed`, and
  `cachedIdentifierSuffixReassessmentStopsAfterCurrentUnresolvedDecision` passed all 3 tests (including 3
  identifier-reason cases).
- Raw output: `/private/tmp/R120-02-point1-red-parser-behavior.log`,
  `/private/tmp/R120-02-point1-red-recovery.log`, `/private/tmp/R120-02-point1-green-parser.log`, and
  `/private/tmp/R120-02-point1-green-recovery.log`. An earlier parser RED compile attempt was due to the new API
  not existing; an initial GREEN exposed two incorrect test expectations, corrected before the passing run.
- Review correction I1: edition recognition now requires the immediately preceding token to be a year, and the
  public detector applies the parser's database-suffix removal. Regressions preserve `1984.Final.Cut`,
  `1917.Special.Edition`, and `Summer.of.1984.The.Final.Cut` as titles. Focused reruns passed; logs are
  `/private/tmp/R120-02-point1-review-green-parser.log` and
  `/private/tmp/R120-02-point1-review-green-recovery.log`.
- Point 1 independent review: PASS, no Critical/Important findings; I1 resolved. Point 2 implementation and focused
  checks are complete, with I2/I3 resolved. Point 3 is complete, with I4/I5 resolved; whole-issue review PASS.
- Point 2 representation detail: keep immutable search metadata and its equality/cache fields unchanged.
  `MovieYear` values are projections of the primary year and dated provider events; multiple events for a movie
  retain multiple year values. Carry accepted release events separately with the match and saved folder identity,
  avoiding duplicate writable date/year state or enriched metadata that cannot round-trip through search caching.
- Point 2 focused RED: the original matcher returned only the exact primary-year ID (`[2]`) instead of
  near/exact/unknown IDs (`[1, 2, 3, 5]`); see `/private/tmp/R120-02-point2-red-candidates.log`.
  Unknown-country validation also failed before its correction; `/private/tmp/R120-02-point2-red-country.log`.
- Point 2 transport GREEN: `swift test --package-path Packages/Network --disable-sandbox` with writable temporary
  module/cache/config/security paths and `--filter releaseDates` passed all 10 tests, including parameterized
  invalid provenance/timestamps/responses, complete empty results, UTC projection, authentication/backoff, and
  cancellation. Log: `/private/tmp/R120-02-point2-green-network.log`.
- Point 2 Common focused GREEN: source `scripts/test-support/common-tests.sh`, then `common_swift test --no-parallel
  --filter "releaseYear|MovieMatcherTests|verifiedAlias|alternativeTitle|cachedIdentifier|cachedEdition"`
  passed 44 tests. Log: `/private/tmp/R120-02-point2-focused-common.log`. Coverage includes the eleven-request
  ceiling, six-ID refusal even with cached aliases, alias-before-year ordering, unsupported/unknown/empty/failed
  evidence, exact-versus-corroborated competition, once-only review of older unresolved results, source-event round trips,
  missing-artwork/failure/repair/Refresh rewrites, explicit same-ID supersession, and cancellation.
- Point 2 review corrections I2/I3: dated provenance was lost on failed cache repair and same-ID exact-primary-year
  reassessment. Both reproduced RED before correction in `/private/tmp/R120-02-point2-red-repair.log` and
  `/private/tmp/R120-02-point2-red-same-identity.log`. Shared retention now requires the current folder fingerprint
  and confirmed movie ID; changed fingerprints do not inherit old events, and explicit selection clears them.
- Point 2 independent review: PASS after I2/I3 corrections, with no remaining Critical/Important findings.
  A fresh Refresh commits its newly matched identity/provenance only after successful artwork and assignment;
  earlier download/assignment failure preserves the prior committed identity and its dated provenance.
- Point 2 integration GREEN: `common_swift test --no-parallel --filter
  "MovieFolderProcessorTests|MoviePosterActionTests|MovieMatchingConfigurationProcessing|CollectionProcessingIntegrationTests|ProcessingRecoveryTests|CredentialRevisionTests"
  --skip legacyCacheFailureSurvivesSkippedRetry` passed 99 tests in 8 suites. Log:
  `/private/tmp/R120-02-point2-integration-common-green.log`. The fixture for 2020 scale-processing folders now
  supplies an explicit 2020 primary provider year independently of the unfiltered search request.
- Point 2 matcher coverage also explicitly refuses fuzzy-only `Alian` title evidence when nearby release-year
  events otherwise corroborate the year (`VerifiedReleaseYearTests.releaseYearRequiresBothEligibleEventYears`).
- Point 2 focused identity/selected-retry safety GREEN: `common_swift test --no-parallel --filter
  "automaticReassessmentRequiresExplicitIdentityChange|failedReassessmentRetainsConfirmedIdentity|refreshRejectsMissingOrBlankArtworkBeforeDownload|languageOnlyChangeRetainsConfirmedIdentity|languageChangeRetainsIdentityWithoutArtwork|selectedRetry"`
  passed 21 tests. Log: `/private/tmp/R120-02-point2-safety-common.log`. `git diff --check` passed.
- An initial 100-test integration run reported that fixture mismatch and the unchanged
  `legacyCacheFailureSurvivesSkippedRetry` missing-`schemaVersion` failure; the latter was independently reproduced
  on immutable baseline `53a3908` (`/private/tmp/R120-02-baseline-legacy.log`) and remains unmodified. Original
  output: `/private/tmp/R120-02-point2-integration-common.log`. An earlier concurrent run stalled and was stopped
  (exit 130); serial execution completed. A transient unchanged-actor compiler diagnostic disappeared on retry;
  a fresh temporary-scratch build also passed the 9 then-existing year tests. These were focused coherence checks,
  not the formal Validation or Acceptance Testing phases.
- Formal Validation, SwiftLint, Acceptance Testing, native UI qualification, commit, merge, and push not authorized.
- Point 3 focused RED: `MoviePosterActionViewModelTests.editingSubmittedQueryOrYearClearsSearchState` failed for both
  title and year edits, retaining stale results and selected ID; log `/private/tmp/R120-02-point3-red-viewmodel.log`.
- Point 3 focused GREEN after review corrections: `scripts/test-poster-action-ui.sh` passed all 14
  `MoviePosterActionViewModelTests`, including stale-input invalidation while an entered provider search is held,
  cancellation drain, configuration invalidation, review-only suggestion state, and explicit selection/application;
  log `/private/tmp/R120-02-point3-review-i5-green-host.log`.
- Point 3 suggester GREEN after review corrections: `scripts/test-support/test-host-features.sh
  MovieTitleSpellingDifferenceCheckerTests` passed 8 tests,
  covering four edit kinds, exact accent normalization, numeric/short/multiword refusal, localized/original title
  order, inclusive title/query-word bounds, oversized inputs, independent candidates, and the documented Alien/Aliens
  possible false positive; log `/private/tmp/R120-02-point3-review-i4-green.log`.
- Review correction I4 RED: an overlong 65-character query word incorrectly suggested the 64-character provider
  word; `/private/tmp/R120-02-point3-review-i4-red.log`. Normalized query words now receive the same 64-character
  bound as candidate words. Review correction I5 replaced the timing-only fake with an entered-search continuation,
  released only after query/year or configuration invalidation; resulting state remains empty and cancellation drains.
- An initial helper expectation incorrectly rejected the approved Alien/Aliens heuristic result; it was corrected to
  preserve the explicit possibility marker and is not identity evidence. Whole-issue independent re-review passed
  with no open Critical/Important findings. Rendered UI, formal Validation, and Acceptance Testing were not performed.

## Native compilation and build side effects

- Unsigned native Debug macOS arm64 host and embedded Finder build succeeded (exit 0):
  `/private/tmp/R120-02-native-build.log`. Only AppIntents metadata extraction warnings were reported.
  This build preceded the final private spelling-boundary correction and status-string wrapping.
- Despite `REGISTER_APP_WITH_LAUNCH_SERVICES=NO`, Xcode ran `RegisterWithLaunchServices` against its temporary
  `/private/tmp/R120-02-native-RMfxEs/DerivedData/Build/Products/Debug/MovieFolderPosters.app`. No app launch was
  observed. The temporary host and embedded-extension LaunchServices entries were removed with `lsregister -u`
  against that exact build app. A subsequent filtered LaunchServices dump found no matching temporary path.
  PlugInKit was inspected before/after: the same two pre-existing registrations remained; no temporary registration
  was present. Unrelated/current installations were not removed or re-registered.
- Local Xcode build specifications expose no verified switch to suppress this synthesized registration task.
  The final host sources were compiled using the native build's exact underlying `swiftc` arguments, extracted
  and verified before execution without a shell or Xcode build-system invocation. All 50 source compile jobs and
  module emission succeeded (exit 0), including the final helper and view-model corrections, without registration
  or launch. Log: `/private/tmp/R120-02-native-final-host-compile.log`. This is native-configuration host compilation,
  not a second full app/Finder bundle build or final bundle/link qualification.
- Xcode also reordered one unchanged package-product entry in `project.pbxproj`; that generated-only reorder was
  reverted precisely. The project file has no resulting change.

## Phase boundary

Implementation changes remain uncommitted on the feature branch. Approval of the completed Implementation Phase
is required before its commit. Formal issue-scoped Validation (including SwiftLint and Swift Style Guide review)
and Acceptance Testing require their own authorization. Live TMDb, rendered UI/accessibility and Finder runtime
qualification remain unperformed. The known baseline legacy-cache fixture failure remains separately recorded above.
