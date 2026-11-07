# R120-04 — Explicit identifiers and opt-in local information

Issue: https://github.com/AIBeCe/MovieFolderPosters/issues/18

## Authorization and phase

All six proposal points and the subsequent eight naming points were individually approved.
The user approved the Implementation Phase; its changes were committed as `04019a5`.
Acceptance Testing and the AT-01–AT-22 scenario/test additions are now explicitly approved.
Acceptance changes must remain uncommitted until the user approves the completed phase.
Formal Validation, merge, and push are not authorized. Preserve unrelated Xcode user data and parser SwiftPM state.

Baseline: current develop, tracked tree clean at start. Work on feature/explicit-identifiers-local-information.
Use Information terminology throughout new code, documentation, and UI. Existing unrelated Evidence APIs
need not be renamed. No new module, dependency, watcher, polling, recursion, or movie-content writes.

## Approved points, executed in order

### 1. Labelled identifiers and provider lookup

- Typed, bounded parser separate from release-name title parsing, supporting explicitly labelled TMDb and
  IMDb identifiers. TMDb IDs are positive integers; IMDb IDs use bounded tt-digit syntax. Reject malformed,
  zero, overflow, and conflicting IDs; collapse identical repeats.
- Extend existing Network/TMDbClient and MovieMetadataProvider boundaries with direct movie lookup and IMDb
  resolution. Preserve shared recovery/backoff, cancellation, language capture, and provider validation.
- Resolve all recognized identifiers consistently; disagreement leaves the movie unresolved. Provider failures
  cannot fall through to an automatic assignment based on weaker information.
- Keep existing poster availability, current authorization/identity, ownership, and suppression safeguards.
- Focused parser/provider/processor tests, including malformed responses, invalid IDs, and conflicts.

### 2. Opt-in settings

- Add independent Bool settings readsNFOInformation, readsImmediateVideoNames, readsImmediateImageNames,
  default false, in existing MovieMatchingConfiguration global defaults and per-collection overrides.
- Explicit storage migration; preserve existing settings and stored outcomes. Update strict current encoding,
  summaries, services, configuration checks, and existing native Settings/collection-edit controls.
- Clear descriptions of read-only, immediate-file scope. Filename reading does not inspect image/video content
  or select local artwork. Use existing programmatic AppKit hierarchy and controls.
- Focused defaults, round-trip, migration, overrides, presentation, and stale-configuration checks.

### 3. Bounded safe reads and precedence

- Extend existing FileSystem service with narrowly scoped operations for enabled sources only, inside one
  authorized immediate movie directory. Reject symlinks/nonregular files; no descent into directories.
- Read NFO bytes only. Video/image sources read filenames and metadata only. Confirm captured folder identity
  before/after reads. Protect against file replacement and path races using existing descriptor mechanisms
  where applicable; fail closed on changed identity or incomplete reads.
- Information exists in memory during attempt; persist only bounded digests/provenance/outcomes, no raw NFO data.
- Precedence: valid labelled identifiers, NFO identifiers/titles, video filenames, image filenames, folder-name
  fallback. Lower sources cannot override higher sources. Conflicting validated identifiers, equally ranked
  distinct interpretations, or incomplete selected information cannot establish a unique automatic match.
- Image filenames contribute identity only; use existing conservative exact title/year/provider matching.
- Keep explicit manual searches using the title/year the user entered; explicit selection remains authoritative.
- Focused tests for disabled reads, nonrecursive inventory, symlinks, replacements, invalid NFO, conflicts,
  and successful opt-in matching through real processing boundaries with isolated disposable directories.

### 4. Freshness and saved decisions

- Add optional localInformationReadResultSHA256 to folder automatic-assessment cache records. Hash relevant enabled
  filenames, file identities, and bounded NFO contents without persisting their contents.
- Ordinary authorized visits inspect current enabled information before reusing unresolved decisions. Changed
  information allows reassessment; unchanged information retains current retry/manual-resolution behavior.
- Recheck information after provider waits and immediately before icon assignment; discard changed attempts.
- Preserve explicit selections and installed posters. Information changes alone never silently replace a
  confirmed movie. Do not synthesize visits or add scanning triggers when settings change.
- Fix language-only configuration comparison to include all three new settings. Extend explicit migration.
- Focused tests for unchanged/changed inputs, in-flight changes, settings, migration, explicit selections.

### 5. User-visible explanation and manual resolution

- Add MovieIdentitySource cases validatedIdentifier, nfoInformation, videoNameInformation, imageNameInformation.
- Existing folder details explain 'Matched using' identifier/NFO metadata/video filename/image filename.
- Add FolderProcessingReason.conflictingMovieInformation and wire outcome, result, retry, detail, log mappings.
- Guidance: 'The movie information disagrees. Choose the intended movie manually.' Unchanged conflict requires
  manual resolution, using existing Choose Movie flow. Explicit selection remains authoritative.
- Focused provenance, descriptions, no automatic conflict loop, and manual-resolution regression tests.

### 6. Supported inputs and budgets

- NFO XML with movie root; labelled TMDb/IMDb uniqueid elements, title, originaltitle, year. Reject DTD and
  external entities; never fetch referenced resources. Reject malformed/oversized NFO as unusable information.
- Video extensions, case insensitive: mkv, mp4, m4v, avi, mov, mpg, mpeg, ts.
- Image extensions, case insensitive: jpg, jpeg, png, webp, heic, tif, tiff, bmp, avif.
- Generic names poster, cover, folder, fanart, sample, trailer do not establish movie identity. Filename stems
  use the existing conservative release-name parser; do not heuristically strip title words.
- Maximum 1,024 directory entries, 8 NFO files, 256 KiB per NFO, 1 MiB total NFO bytes per movie folder.
  Exceeding a limit marks that source incomplete. Partial reads/scans cannot establish uniqueness.
- Tests cover supported formats, generic names, malformed/unsafe XML, exact limits, and conflicts.

## Execution and handoff

- [x] Point 1 implemented and focused checks recorded (dedicated source/reason labels follow point 5).
- [x] Point 2 implemented and focused checks recorded.
- [x] Point 3 implemented and focused checks recorded; independent review PASS after I2/I3.
- [x] Point 4 implemented and focused checks recorded; scoped independent review PASS.
- [ ] Point 5 implemented and focused checks recorded.
- [x] Point 6 format/budget checks integrated and recorded with point 3.
- [ ] Independent whole-issue review PASS; no open Critical/Important findings.
- [x] Implementation approved and committed as `04019a5`.

Use Swift Testing for unit/integration tests and installed swift-style-guide for Swift edits/review. Run only
issue-relevant focused coherence checks during implementation, with raw logs in /private/tmp/R120-04-*.log.
No SwiftLint until separately authorized Validation. Acceptance permits isolated test-app launches and icon
operations only on disposable test folders. No Finder registration, live credentials, or user movie-folder
mutation. Formal four-part Validation still requires separate authorization. Existing R120-03 acceptance
limitations are historical, not this issue's PASS.

## Findings, decisions, and results

Implementation checks and review findings are recorded below. Formal Validation has not started.
Acceptance Testing is in progress: the dedicated acceptance scheme builds, and the existing isolated native
window smoke test passed (one test, zero failures; `/private/tmp/R120-04-acceptance-native-main.log`).
This readiness result does not establish R120-04 scenario coverage. No Finder registration or live-user-data
runtime checks have been performed. Detailed BDD coverage/results belong to the acceptance specifications/report.

- Branch created from develop; unrelated untracked files preserved. One implementation worker owns source
  and tests across the points; Root owns documentation and design decisions. Independent final review follows.
- Identifier syntax is bounded to existing bracketed database suffix conventions: labelled TMDb positive
  Int32 and IMDb tt plus 7–10 ASCII digits (including the existing bracketed tt form). TVDb/Wikidata remain
  release metadata, not lookup sources. Malformed recognized labels must not silently fall through.
- Official [TMDb details](https://developer.themoviedb.org/reference/movie-details) and
  [find](https://developer.themoviedb.org/reference/find-by-id) contracts support captured language.
  Find returns mixed media categories; consume movie_results only, require a unique movie identity, and
  reconcile every supplied ID. Optional no-match results cannot authorize lower-source fallback when a
  recognized identifier is unresolved. No live provider calls were made for this research.
- Fresh local information must be checked before cached unresolved/manual-resolution/backoff gates.
  validateSelectedCandidate currently short-circuits ordinary automatic visits; a selected-retry-only check
  cannot protect all automatic paths after provider waits. A dedicated all-path freshness check is required.

### Point 1 focused implementation evidence

- Typed identifier parser and direct Network lookup APIs implemented; direct processor integration bypasses
  weaker title/year matching when recognized identifier information is present. Unsupported injected providers
  fail closed. Dedicated provenance/conflict labels are deferred to point 5 as planned.
- Network: 7 Swift Testing declarations passed, including parameterized invalid IDs, malformed records/find
  responses, mixed-media exclusion, language and request URL. Log: /private/tmp/R120-04-point1-network-green.log.
- Common: 5 declarations passed, including invalid/deduplicated parser input, real processor conflicts/provider
  failure without fallback, identifier-only assignment via recording adapter, and shared credential rejection.
  Log: /private/tmp/R120-04-point1-common-green.log.
- Parser RED was missing-new-API compilation, not an executed behavioral failure:
  /private/tmp/R120-04-point1-common-red.log. Initial Network RED was blocked by module-cache permissions.
  Writable temporary caches allowed subsequent runs. No full behavioral RED claim for point 1.
- Detailed worker report: /private/tmp/R120-04-point1-report.md. No formal Validation/Acceptance, native launch,
  registration, credential access, user movie-folder mutation, or commit performed.
- Independent point-1 review PASS: no Critical/Important findings. Whole-issue review remains pending.
  Point 4 must also adopt the new identifier rules once for old unconfirmed labelled-folder outcomes, even
  when local reading is disabled; old cache gates must not indefinitely retain weaker matching decisions.

### Point 2 focused implementation evidence

- Three independent false-default options implemented globally and in collection setup/edit overrides, using
  native AppKit checkboxes and filename/read-only scope copy. Source-only saves use passive configuration
  reloads; other existing setting/inclusion scheduling semantics are retained.
- Current settings/outcomes/operational schemas are 8/4/2. Explicit conversion fills false options in global
  settings, overrides, current/historical processing contexts and operational matching configuration.
  Current schemas require all three flags. Existing values, unknown fields, authorizations, generations,
  saved identities/outcomes and versioned query data are preserved.
- Common: 82 test declarations in 8 directly affected configuration/migration/state/store suites passed.
  Log: /private/tmp/R120-04-point2-green.log. Host source-copy harness: 14 declarations passed.
  Log: /private/tmp/R120-04-point2-host.log. This compiles actual host/Finder sources without app launch.
- Initial RED observed missing option properties (/private/tmp/R120-04-point2-red.log), not an executed
  behavioral assertion failure. Intermediate checks caught a migration guard regression, missing store schema
  gate, stale schema-sensitive fixtures and keyboard-loop expectations; corrected before final green runs.
- Detailed report: /private/tmp/R120-04-point2-report.md. Independent review PASS after I1. No rendered-app
  visual validation, formal Validation/Acceptance, lint, credentials, registration, user data, or commit.
- Review I1 (Important, RESOLVED): new settings6/7 conversion reused directory normalization whose required
  isPrivate/participationPolicy guard covered only schema5. Missing fields could acquire unsafe defaults.
  The guard now retains required-field rejection for schemas5...7. Four schema6/7 missing-field scenarios
  failed behaviorally before correction; 24 focused tests passed after correction. The same reviewer
  inspected the correction/tests and evidence and returned point2 PASS. No remaining point2 blocking findings.

### Point 3 safety review

- Descriptor-backed FileSystem capture implemented with initial isolated checks; Common interpretation and
  matching integration in progress. Point6 exact budget and format coverage is implemented alongside reader
  behavior rather than duplicated in a later pass.
- Safety review S1 (Important, RESOLVED): per-file post-read checks alone miss an earlier file edited in place
  during later enumeration. Add final bounded selected-entry fstatat sweep and deterministic mutation
  regression before complete capture returns; retain final directory/path checks. Correction adds a final
  selected-entry type/identity/size/mtime/ctime sweep; deterministic real-FS regression changes an earlier NFO
  before the sweep. Three reader tests passed (/private/tmp/R120-04-point3-S1-green.log), and the same safety
  reviewer returned scoped re-review PASS. (Safety review originally called this I1; S1 distinguishes it
  from the resolved settings-migration I1.) Whole-issue safety/freshness review remains pending.

### Point 3 and point 6 focused implementation evidence

- Descriptor-backed opt-in capture and strict XML interpretation implemented; all enabled folder/NFO/filename
  IDs reconcile before NFO/video/image/folder title precedence. Generic stems provide no identity. Media
  contents are never opened; no local artwork is selected. Raw NFO data stays in memory.
- Exact inclusive limits and all supported extensions covered. FileSystem: 8 test declarations passed,
  including 17 extension variants, disabled reads, nonrecursion, symlinks, replacement, in-place mutation,
  exact/over entries, NFO count, individual size and aggregate size.
  Log: /private/tmp/R120-04-point3-filesystem-green.log.
- Common: 51 processor/regression declarations passed serially
  (/private/tmp/R120-04-point3-common-serial.log); final issue-focused 12 declarations passed after additional
  image enable/disable fixtures (/private/tmp/R120-04-point3-common-focused.log). Selections overlap.
- API-missing compile RED for reader/parser is distinct from behavioral RED. S1 has genuine deterministic
  real-FS mutation RED/GREEN. An initial hidden-folder fixture was corrected to a visible folder. A combined
  parallel Common run stalled and was stopped by terminating only owned processes; it is not a passing run.
  Retried focused checks serially without competing lock waiters.
- UTF-8 and BOM UTF-16 NFO fixtures pass, unsafe XML is rejected, external entity resolution disabled. An
  exploratory UTF-32 positive expectation was removed because XMLParser rejected it; no UTF-32 support claim.
- Detailed report: /private/tmp/R120-04-point3-report.md. Digest capture exists; persistence/reuse/in-flight
  fences remain point4. Whole-issue release readiness is not claimed at this intermediate state.
- General review I2 (Important, RESOLVED): interpolating raw NFO uniqueid into bracket syntax permits suffix junk
  such as `348]junk` to be truncated to a valid TMDb ID. Validate the complete raw value directly.
- General review I3 (Important, RESOLVED): concatenating repeated typed IDs and reparsing the combined string
  applies the folder-input 4 KiB limit to otherwise valid bounded multi-file captures. Deduplicate typed IDs
  directly and preserve real same-provider conflicts. Same Worker/Reviewer own correction and re-review.
- Both corrections have behavioral RED followed by 15-test GREEN, including TMDb/IMDb suffix junk and a real
  400-file repeated-ID capture with a conflicting-ID variant. Same reviewer inspected corrections/evidence
  and returned point3 PASS with no open Critical/Important findings.

### Point 4 focused implementation evidence

- Optional localInformationReadResultSHA256 persists only an automatic-assessment digest. Operation-local capture/context
  retains at most one folder. Enabled information is checked before unresolved/retry cache gates, per provider
  page/identifier/alias/date response and failures, after artwork suspension and inside final synchronous
  assignment admission. Ordinary, selected retry and fresh automatic refresh paths participate.
- Changed in-flight attempts become interrupted without retaining a newly matched identity; changed unconfirmed
  inputs can reopen an assessment at an ordinary authorized visit. Confirmed/explicit decisions and installed
  posters remain protected. Matching revision2 adopts old unconfirmed labelled-ID outcomes once even when all
  local options are off, without reapplying unrelated year-revision migration.
- Behavioral RED: two test declarations reproduced eight issues before correction
  (/private/tmp/R120-04-point4-red.log). Serial affected processor/manual/selected regressions: 71 declarations
  in two suites passed (/private/tmp/R120-04-point4-green.log). Final issue-focused freshness selection:
  seven declarations passed (/private/tmp/R120-04-point4-focused.log). Selections overlap.
- Coverage includes changed/unchanged NFO, raw data nonpersistence, search/artwork/final-admission mutations,
  confirmed/explicit preservation, fresh refresh, legacy-ID adoption and selected negative reopening.
  Recording assigners and disposable directories protect live data. No parallel or stalled run in point4.
- Report: /private/tmp/R120-04-point4-report.md. Independent source review found no Critical/Important defects;
  scoped review PASS after execution-evidence review. Point5 source and conflict descriptions remain pending.
