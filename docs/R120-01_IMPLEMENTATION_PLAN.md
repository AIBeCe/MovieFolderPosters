# R120-01 — Verified aliases and search language

## Authorization and state

All five proposal points and their naming corrections were approved in chat on 2026-10-29.
The user explicitly authorized implementation. Implementation was performed on
`feature/verified-aliases-and-language`, based on develop at `5dbfcfd`.
Implementation and independent review were completed. The implementation commit is `5c6ab52`, the validation
commit is `7ecc50e`, and the acceptance coverage and fixture commits are `e6f0265` and `3eb3127`.
The completed feature branch was fast-forwarded into `develop` on 2026-10-30 at `3eb3127`. The user approved
the Validation and Acceptance Testing phases and later authorized feature completion. Full-app A1–A3 execution
remains blocked and is explicitly recorded in the acceptance report; it is not represented as passing.

Issue: https://github.com/AIBeCe/MovieFolderPosters/issues/15
Release direction: 1.2.0, identification evidence and correction. Finder remains the browser.

## Goal and architecture

Accept exact provider-verified alternative/original titles and explicit search-language choices without
relaxing complete-evidence, year, unique-ID, authorization, ownership, or suppression requirements.
Network retrieves metadata; MovieFolderCommon owns matching, operational decisions, cache and migration;
programmatic AppKit and existing MVVM-C owners present and persist choices. No additional module,
dependency, daemon, watcher, polling, or movie-content mutation.

## Approved names and interfaces

- `MovieAlternativeTitle`: individual provider title, countryCode, title, type; Codable/Equatable/Sendable.
- `public typealias MovieAlternativeTitles = [Int: [MovieAlternativeTitle]]`.
- Private Decodable transport response maps TMDb's `{id,titles}` JSON to that dictionary.
- Rename existing `TMDbRequestPurpose` to `TMDbRequestCategory`; preserve existing serialized category raw values.
- `alternativeTitles(movieID: Int) async throws -> MovieAlternativeTitles` on TMDbClient and MovieMetadataProvider.
- `TMDbLanguage`: validated ISO two-letter language plus optional two-letter country, canonical casing,
  string Codable, Equatable/Hashable/Sendable; `.english` is `en-US`.
- `searchMovies(title: String, year: Int?, language: TMDbLanguage) async throws -> MovieSearchResult`.
  No protocol fallback silently ignoring the selected language.
- `MovieMatchingConfiguration.searchLanguage`, default `.english`; strict current-format decoding.
- Rename `reconcileMovieMatchingConfiguration` to `updateMatchingConfiguration`.
- Rename affected matching UI handlers to `matchingConfigurationChanged` (no `policyChanged`).

## Point 1 — Network evidence

- [x] Add Network title model, private transport decoder, and authenticated alternative-title endpoint.
- [x] Validate positive requested ID, matching returned ID, JSON shape/content type, nonempty title text.
  Empty title lists are valid completed evidence. Preserve country/type; do not rank by them.
- [x] Reuse existing bounded transport, cancellation, safe errors, observer, and category history.
- [x] Rename request category throughout actual code/tests and safe UI rendering; keep raw values stable.
- [x] Tests: endpoint/header/provenance/empty list/wrong ID/malformed response/auth/429/cancellation.

## Point 2 — Conservative matching and budget

- [x] Preserve exact normalization, original-title flag, exact supplied year, complete page,
  consistent unique ID, and artwork-independent identity resolution.
- [x] Reject invalid/incomplete/already-ambiguous results before extra requests.
- [x] Consider all distinct year-compatible IDs, including direct-title matches; never bypass unchecked aliases.
- [x] Fixed maximum five candidate IDs per assessment; six or more yield zero alias requests and
  `.incompleteTitleEvidence`, mapped to persisted `.manualMatchingRequired`.
- [x] Sequential alias requests; deduplicate IDs; no extra pages, retries, or fallback searches.
- [x] Recovery wrapper admits each alias call and records provider failures consistently.
- [x] Validate complete dictionary evidence for requested IDs; do not treat missing/failed evidence as an empty list.
- [x] Wire automatic identification and re-identification through the same rules; explicit selection remains explicit.
- [x] Tests: exact alias, wrong ID/year, cross-ID alias/direct ambiguity, duplicate conflicts,
  poster-independent ties, five/six boundary, no requests for incomplete page, cancellation/failure stops assignment.

## Point 3 — Language

- [x] Add validated TMDbLanguage and persist effective language in global/collection matching configuration.
- [x] Accept language-only and language-country ISO values; normalize `PT-br` to `pt-BR`;
  reject malformed, unknown, whitespace, script/extra components.
- [x] Existing collection override inheritance remains whole-configuration inheritance.
- [x] Automatic/re-identification/Choose Movie use the effective captured collection language.
- [x] One language per assessment; do not translate query, infer from OS changes, filter aliases by country,
  alter artwork policy, or issue fallback searches.
- [x] Tests: validation, round trip, inheritance/override, actual query parameter, forwarding and stale-context fencing.

## Point 4 — Cache, identity, and migration

- [x] Extract shared matching migration helpers into `MovieFolderStorageMigrator+MatchingConfiguration.swift`.
- [x] Group metadata cache ownership in `MovieFolderProcessor+MetadataCache.swift`.
- [x] Structured-encoded then digested keys contain request category, cache format revision,
  exact trimmed search/title/year or movie ID, language, credential revision, fixture/production context.
  Isolated callers may retain absent credential revision; production supplies a revision.
- [x] Cache validated alias evidence separately from decisions with movieID/titles/createdAt.
  TTL uses existing query lifetime (24h); successful empty lists are cacheable, failures are not.
- [x] Alias cache per root: at most 128 entries and 512 KiB encoded; oldest first eviction, deterministic ties.
  Oversized evidence may be used for current assessment without persistence. Never evict folder decisions.
- [x] Credential changes clear both metadata caches. Retain the five-candidate ceiling even on cache hits.
- [x] Language-only changes retain saved confirmed IDs/poster paths/provenance and invalidate unconfirmed decisions.
  Preserve explicit selections. A different automatically resolved ID for unchanged confirmed folder evidence
  requires explicit user selection; retain previous identity evidence and report manual resolution.
  Include already-marked reassessment cases and directly affected result projections.
- [x] Current settings schema 5 -> 6; outcomes schema 2 -> 3, including historical contexts;
  unversioned operational ProcessingState -> schema 1.
- [x] Explicit migration supplies `en-US` only to recognized old matching configurations; absent collection
  override remains absent. Current readers reject missing/invalid required language and old formats.
- [x] Migrate configured operational records in current processing namespace without dropping decisions,
  fingerprints, provenance, poster paths, revision values, provider backoff, or retry evidence.
  Discard legacy query evidence lacking request context. Do not rotate processingCacheRevision.
- [x] Extend existing preflight/report/presentation/composition/backups to account for operational records.
  Reuse original-byte backups and resumable per-record commits, respecting root coordination and leases.
  No networking, movie-directory inspection/mutation, automatic reader upgrades, or credential access.
- [x] Tests: key isolation, TTL/empty responses/limits, confirmed identity retention/conflict, all migration
  formats, historical contexts, exact backups, contention/cancellation/repeat migration and malformed current data.

## Point 5 — Native controls and delivery evidence

- [x] Reusable native MovieSearchLanguagePicker (NSPopUpButton) under UI/Controls.
  Local recognized ISO/language-country choices; localized sorted labels; preserve missing saved choice by insertion.
  Use AppKit's select(_:) directly; the accidentally recursive helper in the draft proposal was explicitly removed.
- [x] Settings Matching Defaults row; immediate existing-model save, failure restores saved state.
- [x] Add/Edit Collection row; inherited effective selection displayed disabled, existing draft/Add/Save/Cancel.
  Copy full matching configuration when editing so other fields are retained.
- [x] Choose Movie discloses effective language beside existing local title/year preview, using authorized context.
  Does not auto-search, add an independent language override, or change confirmed selection implicitly.
- [x] Shared supporting copy: "Requests movie titles in this language. Original and alternative titles can still
  identify a movie. Confirmed movie identities are preserved."
- [x] Manual resolution description becomes "Choose the intended movie manually" rather than year-only copy.
  General help explains complete evidence/unique identity and bounded requests without inventing unsaved causes.
- [x] Retain Settings 700x650 and scrollable collection sheets 580x620, native spacing/colors/typography,
  wrapping help, keyboard/VoiceOver labels, busy/inheritance disabling, Light/Dark system behavior.
- [x] Tests: picker/drafts/inheritance/busy/save failure/cancel/disclosure/reason wording;
  focused host/Finder compile and independent review.

## Execution and review gates

Use meaningful Swift Testing RED/GREEN checks. Capture focused logs in `/private/tmp/R120-01-*`.
No entire-project suite or SwiftLint during implementation. Apply installed swift-style-guide to Swift editing
and review; selected macOS design skills apply to UI. Do not claim rendered/native/live behavior from code/builds.
Worker owns product/test changes; root owns this plan and decisions; persistent reviewer independently reviews
the implementation and routes fixes to the same worker. Stop for material deviations from approved scope.

After implementation, report changed components, focused evidence, and limitations for approval.
Only implementation approval authorizes its commit. Formal Validation Phase requires separate explicit
authorization and all four issue-scoped activities (verification, unit tests, SwiftLint, Swift style review).
Native visual/keyboard/VoiceOver/live-provider qualification must be reported as unperformed unless exercised.
Only "finish the feature" authorizes develop integration, product documentation updates, documentation commit,
and push. Preserve unrelated .DS_Store, Xcode user data, and SwiftPM state.

## Implementation evidence and decisions

- Initial state: no tracked changes; unrelated untracked items preserved. Branch created from `5dbfcfd`.
- Pending: implementation, focused coherence evidence, independent review.
- Implementation interruption: worker and reviewer hit an account usage limit; user requested continuation.
  The same worker/reviewer ownership was resumed. Partial rename edits and Network tests were retained.
- Reviewer preflight: no blockers. Operational migration must follow processor lock ordering;
  confirmed-ID protection must cover pre-existing reassessment and failure paths; the five-ID ceiling
  applies before cache lookup; Choose Movie language disclosure must use an authorized captured context.
- Network initial RED log `/private/tmp/R120-01-network-red.log` demonstrates missing APIs at compilation,
  not a failing behavioral assertion. Network implementation and focused GREEN checks are in progress.
- Initial coherent implementation: Network focused 9 tests passed; Common focused 68 tests in 8 suites passed;
  narrowed host harness 15 tests passed and compiled production host/Finder sources. These are implementation
  coherence checks, not formal validation. Logs: `/private/tmp/R120-01-network-green.log`,
  `/private/tmp/R120-01-common-focused.log`, `/private/tmp/R120-01-host-focused.log`.
- Behavioral identity RED: `/private/tmp/R120-01-identity-red.log` reproduced losing a confirmed ID without
  artwork on language change; focused Common tests cover the correction and retained-ID conflict/failure paths.
- Native unsigned Debug host/Finder build passed (exit 0) at an intermediate review checkpoint:
  `/private/tmp/R120-01-native-build-escalated.log`. Sandbox attempts failed on Xcode nested SwiftPM sandbox
  execution; auto-reviewed escalation permitted the build. Only two expected AppIntents metadata warnings.
  Standard Xcode host LaunchServices registration phase ran; no explicit pluginkit activation or app launch.
  Later product corrections require renewed focused build evidence before implementation completion.
- Original host harness compilation reported Swift actor/init syntax failures in LocalDataExportTests and
  LogViewModelTests. Their baseline status is not established. Narrowed temporary harness excludes those
  unrelated suites; no unrelated source fixes or full-suite qualification is implied.
- Review I1 (Network coverage) resolved and preliminary Network slice PASS. Whole-issue review is ongoing.
- Review I2 (Choose Movie search admitted after failed/cancelled initial language capture) accepted;
  worker is adding a behavioral RED and requiring successful authorized capture before explicit search.
- Earlier `/private/tmp/R120-01-migration-green.log` contained a stale schema-5 assertion failure; its filename
  is not a success claim. Worker reports this corrected and superseded by focused Common GREEN evidence.


## Implementation completion — 2026-10-29

All five approved implementation points are delivered on the feature branch. Requirements above are marked
as implementation-complete; they do not establish formal validation or native qualification. No source
changes were made after the final reviewed build checkpoint. No commit, merge, push, or tracker closure.

| Focused implementation check | Result | Evidence |
| --- | --- | --- |
| Network endpoint, language, category and failure fixtures | 9 tests passed | `/private/tmp/R120-01-network-green.log` |
| Common matching, cache, migration and directly affected integration | 70 tests in 9 suites passed | `/private/tmp/R120-01-common-focused.log` |
| Narrowed host harness, including picker and inheritance globals | 16 tests passed | `/private/tmp/R120-01-host-focused.log` |
| Latest refresh edge cases | 4 tests passed | `/private/tmp/R120-01-refresh-green.log` |
| Unsigned native Debug host and Finder build after all corrections | BUILD SUCCEEDED; exit 0 | `/private/tmp/R120-01-native-build-delivery.log` |
| Persistent independent whole-issue review | PASS; I1-I5 resolved; no Important/Critical findings | `/private/tmp/R120-01-review.md` |
| Tracked whitespace | Clean | `rtk proxy git diff --check` |

Test totals overlap and are not summed. Earlier failed/intermediate logs remain as historical evidence,
not success claims. Native build used auto-reviewed sandbox escalation after isolated temporary cache
attempts could not execute Xcode's nested package sandbox. Build artifacts stay under `/private/tmp`.

Review corrections: I1 completed Network error/category/request coverage; I2 requires successful authorized
language capture before explicit search, including failure/cancellation/reopen; I3 rejects nil/blank refresh
artwork before download; I4 persists retained-ID manual resolution and excludes old identity when the folder
fingerprint changed; I5 persists manual resolution for incomplete title evidence on refresh with zero alias
and artwork calls at the six-candidate ceiling. The same worker/reviewer pair owned all corrections.

Live TMDb, rendered Light/Dark/keyboard/VoiceOver inspection, real saved-data migration and Finder runtime/icon
persistence qualification remain unperformed.
The broad host test harness could not compile unrelated actor/init test declarations; no baseline claim
or full-project test pass is made. Focused host evidence uses a narrowed temporary harness and real production
sources; unrelated test syntax was not repaired. Unrelated untracked files remain preserved.

## Validation and acceptance completion — 2026-10-30

The user approved the completed Validation phase and its commit, `7ecc50e`. The validation work addressed the
reported SwiftLint findings in scope and reviewed the introduced import-order and line-length findings against
the Swift Style Guide. Validation was approved before the Acceptance Testing phase began. Its evidence and
qualification boundaries remain the recorded focused results above; this does not establish live TMDb,
rendered accessibility, Finder runtime, or release qualification.

The user approved the Acceptance Testing phase after reviewing the execution report. Persistent BDD scenarios and
automated tests are in `docs/acceptance/R120-01.md`, committed in `e6f0265` and `3eb3127`. Executed processor,
action-service, and log regression scenarios passed. Full-app UI scenarios A1–A3 did not execute because macOS
blocked the XCUITest runner and the host has no valid development signing identity; their statuses remain BLOCKED.
Acceptance phase approval authorized the documented test deliverables and integration, not a claim that all
full-app E2E scenarios passed. Re-run A1–A3 in a suitably signed/trusted macOS test environment when available.

## Integration — 2026-10-30

`feature/verified-aliases-and-language` was fast-forwarded into `develop`; integrated HEAD is `3eb3127`.
The roadmap and this implementation record were updated on `develop` as part of the authorized feature-completion
sequence. Local Xcode user data and SwiftPM scheme state were preserved and excluded from the feature commits.
