# Movie Folder Posters — Versioned Production Roadmap

Date: 2026-10-16
Status: Versioned product direction approved for documentation; individual implementation approvals are recorded
under their deliverables. Roadmap inclusion alone does not authorize implementation.
Baseline: `develop` at `f07813c` (accepted native AppKit UI). Verify current source before future implementation.

## Purpose and document authority

Ship a dependable 1.0.0, then add coherent capabilities in ordered releases. Account for every original idea;
do not turn 180 brainstorming entries into 180 separate features or make all future ideas block 1.0.

- This document owns release scope, order, dependencies, and exit criteria.
- [Idea triage](IDEA_TRIAGE.md) gives every original E/N idea one primary destination and explains consolidation.
- [UI enhancements](UI_ENHANCEMENTS.md) adds native usability proposals to the accepted three-window design.
- [Project plan](PROJECT_PLAN.md) retains the original Phase 1–7 architecture and implementation evidence.
- [Native AppKit UI](NATIVE_APPKIT_UI.md) owns the accepted current visual direction and screenshot references.
- [Enhancement ideas](ENHANCEMENT_IDEAS.md) and [new feature ideas](NEW_FEATURE_IDEAS.md) remain unchanged historical
  catalogues. Their old alternative UI directions are not current design authority.

This is a production roadmap, not a code-level implementation plan. For each bounded implementation point,
inspect current code, propose actual changes/tests/code, obtain approval, then use TDD and independent review
where appropriate. Approval here does not authorize building every release or skipping those gates.

## GitHub tracking

Repository Issues are the tracker; no separate GitHub Projects board is required. Each consolidated deliverable
has one coded issue and its target milestone. The complete [GitHub tracking index](GITHUB_TRACKING.md) records
verified issue/milestone links. Original E/N and new U ideas link to those issues through their owning deliverables.
Issue creation does not authorize implementation, change release scope, or imply completion.

## Decisions and constraints

- Finder remains the movie browser; the host remains a configuration and focused operational utility.
- Keep Swift 6, programmatic AppKit, MVVM-C, and SOLID where useful. No SwiftUI, speculative abstractions, or new
  glass theme system. Preserve Main, Settings, and Log; use focused sheets for results and correction.
- Keep local in-process Network, FileSystem, and Persistence SPM services. Movie policies stay in application
  source shared with the Finder target as needed. No additional module or third-party dependency is preapproved.
- Do not rename, move, delete, or edit movie contents. Optional NFO/filename/local-artwork evidence is read-only,
  explicitly scoped, and not permission to recurse. Normal collection discovery remains immediate-child-only.
- Native icon metadata mutations require approved scope, current authorization, identity, ownership, suppression,
  and policy checks after asynchronous work and immediately before writing.
- Keep processing finite and tied to authorized roots and extension lifetimes. While Finder observes a configured
  collection, a root-directory event may queue one coalesced rescan and provider backoff may schedule one retry at
  its recorded deadline. Neither trigger survives observation end, configuration reload, or extension termination;
  no launch agent, daemon, persistent scheduler, or wake-up guarantee is introduced.
- Separate authoritative folder outcomes from a bounded activity stream. Derive neither from a screenshot,
  unstructured Console text, or optimistic network requests. Stale/unknown/partial values remain labelled.
- Prefer missing posters to incorrect ones. A suggestion, imported record, old approval, or matching path never
  establishes current permission, stable identity, or ownership of an existing icon.
- Build accessibility/privacy into each feature. Retention limits, cancellation, error semantics, and failure
  recovery are part of its acceptance criteria, not deferred finishing work.
- Current Xcode settings specify macOS 26.5 and Swift 6.0. This is the configured floor, not a proven support
  matrix. 1.0 qualification must confirm the chosen supported OS/hardware/filesystem combinations; changing the
  deployment floor needs a separate reviewed proposal.

## Established baseline and unresolved evidence

The parser, conservative matching, automatic immediate-child processing, ownership/suppression safeguards,
serial/cross-process coordination, services, basic directory/Keychain configuration, and single-folder Finder
commands exist. Extend and verify them instead of rewriting them as new systems.

The accepted native UI provides collection columns, separate Settings/Log, poster choices, and System/Light/Dark.
R100-02 now populates collection counts and read-only details from authoritative persisted processing state.
R100-03 connects host and Finder activity to the bounded persistent Log service through MovieFolderCommon.
Its implementation is committed as `e7d404b` and present in `develop`; GitHub issue #3 remains open.

The UI feature recorded 17 focused tests, signed build/launch, and independent review. This is historical evidence,
not proof of a production release. Prior phase documents have different verification dates and limitations;
reconcile them against current code. Live TMDb, complete current XCUITest execution, reboot, and physical-volume
recovery require explicit current evidence where existing records do not establish it.

Already delivered catalogue items: E31 (window separation), E41 (poster previews), and E42 (light/dark inspection).
Revalidate their behavior in later release checks; do not schedule duplicate implementations.

## Release sequence

Develop and qualify each release in the listed order. Within a release, follow deliverable order unless its
explicit dependency requires an earlier foundation. Feature work remains split into individually approved points.
No dates or effort estimates are promised; estimate only after the current release has scoped technical proposals.

| Target | Focus | Delivery character |
| --- | --- | --- |
| 1.0.0 | Dependable existing core and distribution | First production release; only R100 and baseline regression gates |
| 1.1.0 | Collection usability and operational clarity | Incremental features |
| 1.2.0 | Identification evidence and correction | Conservative matching preserved |
| 1.3.0 | Artwork and offline workflows | Explicit source/policy scope |
| 1.4.0 | Reviewable batch operations | Receipts before saved approvals and undo |
| 1.5.0 | Portable decisions, cache maintenance, recovery | Fresh authorization for restored roots |
| 1.6.0 | Advanced reusable configuration | Uses already-proven settings |
| 1.7.0 | Optional macOS entry points | API feasibility gates; neutral fallback is research-only |
| 1.8.0 | Reports and measured optimization | On-demand evidence, not indexing |
| 2.0 candidates | Larger boundaries and integrations | Investigation and separate approval; not a shipping promise |

These are product planning targets. Backward-compatible fixes use patch releases and compatible features use
minor releases. A major number must reflect an explicit compatibility decision, not simply a large backlog.
Before 1.0, document supported user-facing contracts; validate migrations and exported formats as they appear.
The eventual 2.0 candidate work may fit later 1.x releases if compatibility is preserved. See
[Semantic Versioning](https://semver.org/) for the underlying versioning rules.

## 1.0.0 — Dependable Finder poster utility

Milestone: [1.0.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/2).

Complete and verify the existing core before adding new workflows. Counts and Finder logs must become real; setup, failures, repair, safety, accessibility, and distribution must be dependable.

<a id="r100-01"></a>

### R100-01 — Verify installation, access, and platform readiness

GitHub issue: [#1](https://github.com/AIBeCe/MovieFolderPosters/issues/1); milestone: [1.0.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/2).

Status: **Completed — 2026-10-17.** Issue #1 is closed. The verified feature was fast-forwarded into local `develop`
at `55ba0a6`; its feature branch was deleted. The integration was included in the 2026-10-18 push of `develop`; no release was published.
Implementation evidence: [Installation readiness](INSTALLATION_READINESS.md).
Controlled native evidence and explicit release-qualification limits: [Native qualification](NATIVE_READINESS_QUALIFICATION.md).
Completion satisfies this deliverable's documented-matrix criterion; it does not qualify every filesystem or authorize a release.

- [x] Scope: Audit current behavior first; distinguish disconnected, missing, unauthorized, read-only, and unsupported roots. Explain overlapping roots and reconcile renames only with validated stable identity. Provide bounded checks for extension registration, component versions, shared storage, and enablement guidance; report unknown state honestly.
- Dependencies: Current develop baseline; inspect PROJECT_PLAN.md and NATIVE_APPKIT_UI.md before proposing the first point.
- Acceptance: A documented installation/access matrix covers fresh setup, stale access, unplugged media, read-only storage, overlapping roots, replaced directories, and app/extension mismatch. A root is never marked ready just because its path exists. Native checks distinguish observed activation from user instructions.
- Source ideas: E51, E52, E53, E54, E59, E76, E77, N91, N92, N93, N94.

<a id="r100-02"></a>

### R100-02 — Persist authoritative processing outcomes and collection summaries

GitHub issue: [#2](https://github.com/AIBeCe/MovieFolderPosters/issues/2); milestone: [1.0.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/2).

Implementation is complete, independently reviewed, verified, committed as `049b74b`, and integrated locally
into `develop` using a fast-forward merge. GitHub issue #2 is closed as completed; `develop` was pushed through `b48d44d` on 2026-10-18. See
[Processing results](COLLECTION_PROCESSING.md) for the design, verification, and remaining native qualification.
The state enum is named `FolderProcessingState`; the GitHub deliverable is closed as completed; the merged feature branch is retired.

- [x] Scope: Define operation IDs, folder outcomes, collection snapshot revisions, and retention before connecting Main. Keep outcome records separate from activity events. Show actual Done, Not found, Several matches, and Total with reasons, verified identity, icon ownership, retry eligibility, and last completed run. Preserve unknown, partial, interrupted, and stale states.
- Dependencies: R100-01; inspect existing ProcessingSummary and Persistence APIs.
- Acceptance: Tests pin mutually exclusive folder outcomes, snapshot consistency across processes, interruption and stale revisions. Total is the count of visible immediate child directories in the inspected snapshot, excluding files, hidden entries, and symlinks; ignored/preserved/failed entries remain explainable in details. The three headline outcome counts need not sum to Total. Unavailable summaries never become fabricated zeros.
- Source ideas: E1, E3, E4, E5, E6, E7, E8, E57, E58.

<a id="r100-03"></a>

### R100-03 — Connect bounded Finder and host activity to Log

GitHub issue: [#3](https://github.com/AIBeCe/MovieFolderPosters/issues/3); milestone: [1.0.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/2).

Implementation approved on 2026-10-18: extract shared application code into the local MovieFolderCommon package
and introduce a local Log service package with an Activity folder. Full host/Finder integration is included.
Implementation and independent review passed on `feature/common-and-log-services`. Commit `e7d404b` is
present in `develop` and the locally recorded `origin/develop` at `fd9eb83`. GitHub issue #3 remains open
at live read-back on 2026-10-18. Native Finder/window qualification limits remain explicit in the verification record.
See [Common and Log migration](COMMON_AND_LOG_MIGRATION.md).

- [x] Scope: Add a bounded sanitized activity stream across actual host/extension operations, using existing Persistence capabilities where sufficient. Retain the separate native Log window. Notifications may invalidate views, but persisted records remain authoritative; no timer, watcher, or log-scraping dependency.
- Dependencies: R100-02; event/outcome schemas and privacy rules agreed before storage changes.
- Acceptance: Tests cover concurrent writers, ordering, retention, secret/path redaction, and process restart. Opening Log loads actual recorded activity. Clearing Log never deletes outcome records, matches, configuration, or icons.
- Source ideas: E9.

<a id="r100-04"></a>

### R100-04 — Make network failure and interruption recovery predictable

GitHub issue: [#4](https://github.com/AIBeCe/MovieFolderPosters/issues/4); milestone: [1.0.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/2).

- [x] Scope: Expose authentication, connectivity, server failure, and provider throttling separately. Coordinate provider backoff across extension processes and persist safe progress. Resume eligible unfinished work only on a later authorized invocation. Add a bounded recovery launch path that prevents new processing in participating processes while configuration and diagnostics remain usable.
- [x] Recovery policy: Determine automatic eligibility from persisted state and failure reason; a retry timestamp only gates eligible work. Not found and Several matches require manual resolution and never repeat automatically for the same unchanged folder. Resume eligible temporary failures/interrupted work on a later authorized Finder visit. Reassess legacy records lacking a reason once, bypassing their obsolete retry gate and inconclusive cached decision without clearing unrelated data or repeating verified completed writes.
- [x] Presentation: Separate saved-state freshness from processing completion. Show Needs processing, Waiting to retry, Needs manual resolution, and Complete with relevant counts; mixed conditions remain visible together. Current alone must not imply completion. Full rules: [Processing recovery policy](COLLECTION_PROCESSING.md#approved-recovery-policy--r100-04-and-r100-05).
- Dependencies: R100-02 and R100-03; no new background process.
- Acceptance: Controlled tests cover 401/403, 429 with changing Retry-After, server errors, cancellation, process loss, and a later explicit resume without repeating completed writes. A next-eligible time is never presented as a scheduled execution promise. Recovery mode cannot be bypassed by another entry point or stale process.
- Acceptance: Repeated visits, cooldown expiry, reloads, and process restarts never automatically repeat confirmed Not found/Several matches searches. Eligible retries respect failure policy and shared provider backoff. Legacy reassessment persists its classification and is not repeated after restart; interrupted reassessment resumes safely. Tests cover preserved Done evidence, legacy JSON, and mixed manual/retry/pending collection labels. Manual-resolution controls remain in R100-05. This issue originally added no timer; the later observed-collection bugfix adds an extension-lifetime retry only while Finder continues observing the root.
- Source ideas: E61, E62, E63, E64, N98.

Recovery commit `008a6f3` was fast-forwarded into local `develop` on 2026-10-20. See
[Processing recovery](PROCESSING_RECOVERY.md) for verification and native limits. No push or issue closure was performed.

<a id="r100-05"></a>

### R100-05 — Resolve and retry specific failed folders

GitHub issue: [#5](https://github.com/AIBeCe/MovieFolderPosters/issues/5); milestone: [1.0.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/2).

- [x] Scope: Expose a focused unresolved-results sheet from Main, reuse the existing Choose Movie flow, and allow a bounded selected retry with cancellation. Keep Finder as the browser; there is no persistent movie grid.
- [x] Manual-resolution policy: Not found opens an explicit manual search; Several matches opens explicit movie selection. Neither state is an automatic retry candidate. Selected retries are user-initiated and use R100-04 eligibility/backoff rules; manually requested searches are explicit actions, never scheduled repeats.
- Dependencies: R100-02 through R100-04; reuse MoviePosterActionCoordinator and service boundaries.
- Acceptance: A real unresolved result can open selection, apply an explicit match, or retry. Cancellation prevents later unwanted writes without undoing already completed work. Selection, permissions, and folder identity are revalidated after asynchronous work.
- Acceptance: Manual-required results remain visible until resolved by an explicit action or invalidated by changed folder identity. Opening the sheet and ordinary Finder visits issue no repeated search for those results. Successful manual resolution updates saved state and collection counts without reprocessing unrelated folders.
- Source ideas: E2, E21, E25, E67.

The manual-resolution implementation and its 2026-10-22 observed-processing, parsing, and action-presentation
follow-up are integrated into `develop`. Automated tests, coverage, lint, style, signed builds, and signatures
passed. Live Finder behavior on the user's collections remains unqualified; see
[observed collection validation](OBSERVED_COLLECTION_VALIDATION.md).

<a id="r100-06"></a>

### R100-06 — Make credential setup and replacement understandable

GitHub issue: [#6](https://github.com/AIBeCe/MovieFolderPosters/issues/6); milestone: [1.0.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/2).

- [ ] Scope: Add concise token guidance, an explicit credential test, and deliberate replacement while retaining current secure storage. Show which parsed identification fields a provider request uses; never display the token.
- Dependencies: R100-04; existing Keychain and Network interfaces.
- Acceptance: Invalid/offline/valid tests have distinct safe results. Replacement preserves roots and confirmed matches. Credentials never enter URLs, exported diagnostics, snapshots, or UI errors. Native credential entry is performed by the user for live verification.
- Source ideas: E38, E39, N53, N57.

The combined R100-06 proposal was approved on 2026-10-22. Its implementation and focused-check ledger are in
[credential setup and replacement](CREDENTIAL_SETUP.md). Implementation review and formal validation are separate
gates; this entry does not claim completed release qualification.

<a id="r100-07"></a>

### R100-07 — Complete essential native usability and accessibility

GitHub issue: [#7](https://github.com/AIBeCe/MovieFolderPosters/issues/7); milestone: [1.0.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/2).

- [ ] Scope: Keep Main, Settings, and Log and the accepted AppKit styling. Add conventional Settings/menu shortcuts, helpful empty/busy/error states, explicit access explanations, keyboard alternatives to hover actions, meaningful VoiceOver labels, and stable focus and window behavior.
- Dependencies: R100-01 through R100-06; UI_ENHANCEMENTS.md U01-U05 and U08-U10.
- Acceptance: Automated state/lifecycle checks and native keyboard/VoiceOver checks cover all core workflows, light/dark, increased contrast, resizing, reopening, and asynchronous updates. Status remains understandable without color. UI work for earlier deliverables must already follow these rules.
- Source ideas: E32, E33, E36, E37, E71, E72, E73, E74, E80.

The R100-07 implementation point delivered an accessible Main empty state. Focused presentation and credential-service
tests passed, and repository-wide SwiftLint passed. Commits `1c9e2b0` and `85c348d` are integrated in `develop`.
Native keyboard, VoiceOver, contrast, and window-resizing checks remain pending; this issue is not fully qualified.

<a id="r100-08"></a>

### R100-08 — Handle corrupt cached artwork safely

GitHub issue: [#8](https://github.com/AIBeCe/MovieFolderPosters/issues/8); milestone: [1.0.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/2).

- [x] Scope: Expose invalid/missing cache artwork as recoverable conditions. Reuse the existing validation and ownership mechanisms; distinguish source-cache repair from rewriting folder icons.
- Dependencies: R100-02 and R100-04.
- [x] Acceptance: Corrupt/truncated image tests and missing-source cases cannot produce repeated invalid writes, silent match loss, or foreign-icon replacement. Repair runs only during an explicit processing visit and is bounded to one attempt per poster path in that visit.
- Source ideas: E70.

R100-08 is implemented and validated in `9229177` and `e9be774`, then fast-forwarded into `develop`.
The scoped test, SwiftLint, style, and independent review results—and the unperformed native qualification—are
recorded in [Cached artwork repair](CACHED_ARTWORK_REPAIR.md). The GitHub issue remains open; its state was not
changed as part of this local integration.

<a id="r100-09"></a>

### R100-09 — Qualify and distribute the first production release

GitHub issue: [#9](https://github.com/AIBeCe/MovieFolderPosters/issues/9); milestone: [1.0.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/2).

- [ ] Scope: Finish the app icon, minimal reviewed redacted diagnostic export, installation documentation, TMDb attribution, signed/notarized packaging, and the release matrix below. No update service or App Store distribution is implied.
- Dependencies: All R100 deliverables and completed baseline regression checks.
- Acceptance: Fresh-install and upgrade smoke checks pass on declared supported systems. Debug and Release use the correct transport; live TMDb and native icon persistence are verified independently. No open Critical/Important findings remain. Signing, notarization, user-facing documentation, and attribution are checked.
- Source ideas: E75, E78, E79.

The implementation and scoped validation record is in [R100-09 release readiness](RELEASE_READINESS.md). Commit
`a08c070` is integrated into local `develop`; its release-package workflow has not yet been run with Developer ID
signing and notarization credentials. Native release qualification remains incomplete, so the 1.0.0 release gate
and issue #9 remain open.

### 1.0.0 release gate

All R100 deliverables must pass; later-release ideas do not block 1.0. No new capability is inferred from a
checked document box: attach current test, build, review, and native-observation evidence to its feature record.

#### Supported-platform and qualification matrix

As of 2026-10-22, the project configures macOS 26.5 as its deployment target. This is a build setting, not a
declared or qualified support matrix. No broader macOS version, hardware, or filesystem support claim is established
by the current records. Keep the supported-system declaration open until the release owner selects it using
compatibility evidence; do not infer it from the deployment target or from tests on one development host.

| Release claim | Evidence recorded so far | Required 1.0 qualification |
| --- | --- | --- |
| macOS and hardware support | macOS 26.5 deployment target; prior builds and tests ran on one development environment. | Declare supported macOS versions and hardware explicitly; run fresh-install and upgrade smoke checks on each declared system. |
| Filesystem support | Native APFS and HFS+ inspection and isolated bookmark handoff checks are documented. exFAT could not be mounted for testing; physical-device reconnect and reboot are untested. | State filesystem support and limits from evidence. Qualify any filesystem or reconnect claim that the release documentation makes; preserve unknown status otherwise. |
| Debug and Release behavior | Prior signed Debug build-for-testing and Release build passed; XCUITest execution and current-candidate smoke checks are not established by those builds. | On the release candidate, verify Debug fixture transport and Release live transport separately; run the applicable smoke checks. |
| Live provider access | Controlled TMDb fixtures cover provider behavior; they do not establish live account/token access. | Verify live TMDb access independently with an authorized test account/token and record the result without storing credentials. |
| Native icon persistence | Automated and isolated filesystem checks do not establish Finder custom-icon persistence. | Verify icon assignment and persistence through app/extension termination and Finder restart independently of provider verification. |
| Installation and upgrade | A production clean install and upgrade smoke check are not recorded. | Perform both checks on every declared supported system, preserving existing user data during upgrade verification. |
| Signing and notarization | Earlier signed builds and strict signature checks are recorded; notarization and Gatekeeper assessment of a release package are not. | Verify the release package signature, notarization, and first-open behavior on the declared systems. |

This matrix records current evidence and remaining release work; it does not mark any release gate as passed or waive
unperformed checks. Reconcile it with fresh release-candidate evidence before making user-facing compatibility claims.

- [ ] Core automatic and explicit correction workflows pass with real TMDb access on an isolated collection.
- [ ] Network fixtures cover authentication, backoff, cancellation, corruption, and offline/server failure.
- [ ] App and extension instances cannot bypass configuration changes or duplicate unsafe mutations.
- [ ] Movie names/contents remain unchanged; only approved icon metadata changes occur.
- [ ] Icons persist after app/extension termination and Finder restart; reboot persistence is checked separately.
- [ ] Configured permissions survive restart; unplugged/read-only/unsupported storage is recoverable and honest.
- [ ] Counts/logs have real providers; interrupted and unavailable data cannot masquerade as completed zeroes.
- [ ] Retention is bounded; stored-data evolution has a tested failure/recovery path.
- [ ] Main/Settings/Log work with keyboard, VoiceOver, light/dark, resize, close/reopen, and system contrast options.
- [ ] Debug/Release transport configuration, signing, entitlements, embedding, and clean-install behavior pass.
- [ ] Release packaging is signed/notarized and documentation describes actual supported platforms and limits.
- [ ] TMDb attribution and usage configuration are checked against current provider requirements.
- [ ] No open Critical/Important review findings or unexplained failures remain; unperformed checks are blockers
  when they establish a required release claim. Obtain an explicit scope decision rather than silently waiving one.

## 1.1.0 — Everyday collection management

Milestone: [1.1.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/3).

Improve routine setup, exclusions, private operational views, Finder navigation, and support information.

<a id="r110-01"></a>

### R110-01 — Simplify collection setup and naming

GitHub issue: [#10](https://github.com/AIBeCe/MovieFolderPosters/issues/10); milestone: [1.1.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/3).

- [x] Scope: Accept dropped roots through the same authorization flow as the picker. Add friendly display names and a short setup flow for access and matching configuration; poster appearance remains global in Settings. No profile engine yet.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Drop/picker parity, duplicate roots, access denial, display-name changes, and unmounted roots preserve the correct persistent identity. Setup never implies that enabling an extension grants filesystem access.
- Source ideas: E34, E35, N10.
- Delivery: Implemented in `407f14d`, validated in `763630b`, and integrated into local `develop` at `3c447e0`. The current Finder Sync versus File Providers Settings presentation remains under investigation; see [native qualification audit](NATIVE_READINESS_QUALIFICATION.md#finder-extension-and-file-provider-registration-audit--2026-10-24).

<a id="r110-02"></a>

### R110-02 — Pause collections and exclude folders reversibly

GitHub issue: [#11](https://github.com/AIBeCe/MovieFolderPosters/issues/11); milestone: [1.1.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/3).

- [x] Scope: Unify Finder's Ignore/Include Folder actions and collection excluded-folder settings as one reversible
  inclusion configuration. Pause/resume a collection while preserving its configuration and icons. Keep exclusion
  distinct from durable poster-removal suppression.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Exclusion/pause changes fence in-flight automatic and manual icon changes across processes. Re-enable does not clear unrelated suppression or authorize overwriting foreign icons.
- Source ideas: E29, E55, E56.
- Delivery: Implemented in `0b77cb6` and `6c60ef3`, validation committed as `3bce8de`, then fast-forwarded into local
  `develop`. The focused Swift Testing runs passed (41 package tests, 25 host configuration tests, and 7 setup
  presentation tests). SwiftLint completed with 19 pre-existing warnings on unchanged lines; the Swift style guide
  and `git diff --check` passed. Native Finder menu and icon persistence qualification remains unperformed. Legacy
  serialized configuration keys and Finder URL aliases remain accepted for compatibility.

<a id="r110-03"></a>

### R110-03 — Improve result and Log filtering with private history

GitHub issue: [#12](https://github.com/AIBeCe/MovieFolderPosters/issues/12); milestone: [1.1.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/3).

- [x] Scope: Add result filters plus Log search/category/severity controls and an optional bounded network-purpose ledger. Private collection settings minimize identifying optional history without breaking necessary local state.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Filters operate on actual structured outcomes/events, remain keyboard accessible, and never expose tokens or raw bookmarks. Private mode applies to new events and has an explicit policy for existing history.
- Source ideas: E10, N58, N60.
- Delivery: Implemented in `5b046c7`, extended with informative and fully wrapped Activity messages in `e4d8ad5`,
  and validated in `87d0567`; fast-forward integrated into `develop` on 2026-10-25. The focused formal increment
  checks passed, including actual copy behavior outside the restricted sandbox. SwiftLint reports 0 errors and
  40 warnings (23 unchanged, 17 reviewed numerical metrics). Native keyboard/VoiceOver and live signed host/Finder
  qualification remain unperformed. See [private history](PRIVATE_HISTORY.md) and
  [validation evidence](INFORMATIVE_ACTIVITY_LOG_VALIDATION.md). No release publication or tracker closure is implied.

<a id="r110-04"></a>

### R110-04 — Connect results with focused Finder utilities

GitHub issue: [#13](https://github.com/AIBeCe/MovieFolderPosters/issues/13); milestone: [1.1.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/3).

- [ ] Scope: Open the existing result/evidence sheet from Finder, reveal unresolved children in Finder, and copy verified titles or identifiers. Navigation and copy operations never mutate movie names or icons.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Commands validate selected roots/children, distinguish unconfirmed identity, and reveal only explicitly selected authorized results. An unverified title is never labelled confirmed.
- Source ideas: N31, N32, N33, N34.

<a id="r110-05"></a>

### R110-05 — Explain local data and produce focused support exports

GitHub issue: [#14](https://github.com/AIBeCe/MovieFolderPosters/issues/14); milestone: [1.1.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/3).

- [x] Scope: Show cache/record storage usage and a safe inspector of app-held categories. Extend basic diagnostic export to a user-selected support session; later mutation receipts appear only when R140-01 exists.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Storage estimates identify scope and measurement time. Export preview/redaction excludes secrets, access grants, and identifying paths by default. Export does not send anything to a third party.
- Source ideas: E68, N54, N90.
- Delivery: Implemented and validated on develop; see [Local Data](LOCAL_DATA.md) for behavior and qualification limits.

## 1.2.0 — More accurate identification and correction

Milestone: [1.2.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/4).

Increase supported naming/evidence cases without lowering conservative automatic-matching safeguards.

<a id="r120-01"></a>

### R120-01 — Add verified aliases and language preferences

GitHub issue: [#15](https://github.com/AIBeCe/MovieFolderPosters/issues/15); milestone: [1.2.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/4).

- [ ] Scope: Use provider-verified alternative/original titles and explicit search-language settings. Preserve exact identity and ambiguity safeguards; changing language cannot silently reassign confirmed movies.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: International/alias fixtures prove accepted evidence provenance and preserve ambiguous IDs. Network budgets and cache keys include the relevant language and credential context.
- Source ideas: E11, E12, N77.

<a id="r120-02"></a>

### R120-02 — Improve year, edition, and spelling evidence

GitHub issue: [#16](https://github.com/AIBeCe/MovieFolderPosters/issues/16); milestone: [1.2.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/4).

- [ ] Scope: Recognize edition metadata without stripping title words. Use documented release-date evidence for year differences; suggest likely spelling errors. Nearby years or fuzzy names alone do not authorize assignment.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Realistic ambiguous fixtures and adversarial title/year cases demonstrate no automatic first-result choice. Suggestions remain explicit when corroborating evidence is insufficient.
- Source ideas: E13, E14, E16, E17.

<a id="r120-03"></a>

### R120-03 — Search additional pages within a finite budget

GitHub issue: [#17](https://github.com/AIBeCe/MovieFolderPosters/issues/17); milestone: [1.2.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/4).

- [ ] Scope: Allow bounded pagination and clearly explain when a result set is still incomplete. Apply shared backoff and cancellation instead of fetching every page unconditionally.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: An incomplete result cannot establish uniqueness. Boundary, duplicate-ID, throttling, and cancellation tests stay within an explicitly proposed request/page budget.
- Source ideas: E66.

<a id="r120-04"></a>

### R120-04 — Use explicit identifiers and opt-in local evidence

GitHub issue: [#18](https://github.com/AIBeCe/MovieFolderPosters/issues/18); milestone: [1.2.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/4).

- [ ] Scope: Validate labelled TMDb/IMDb identifiers and support explicitly enabled read-only NFO and immediate video-name evidence. Define precedence and conflicts before combining evidence sources.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Conflicting IDs, malformed NFO, uninformative names, symlinks, and replaced files remain safe. No recursive media scan or sidecar write is introduced; reading movie-adjacent data requires the approved scoped workflow.
- Source ideas: E18, N11, N12, N13, N19.

The earlier parser fix recognizes bracketed database codes only as suffix metadata. This issue still
owns provider-validated identifier matching and any use of NFO or video-name evidence.

<a id="r120-05"></a>

### R120-05 — Remember explicit corrections without renaming

GitHub issue: [#19](https://github.com/AIBeCe/MovieFolderPosters/issues/19); milestone: [1.2.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/4).

- [ ] Scope: Persist folder-specific title/year overrides, deliberate rejections, and reviewed reuse of confirmed identity for equivalent releases. Stable identity and policy changes determine validity.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Saved decisions survive restart, remain inspectable/reversible, and cannot leak to a different folder merely because its path or parsed name matches.
- Source ideas: E19, E20, E24.

<a id="r120-06"></a>

### R120-06 — Make candidate comparison and sequential resolution useful

GitHub issue: [#20](https://github.com/AIBeCe/MovieFolderPosters/issues/20); milestone: [1.2.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/4).

- [ ] Scope: Show candidate artwork, title/year, available country/language/director, and explainable evidence in a focused correction sheet. Allow sequential resolution of selected problems without a library browser.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Sparse provider data is labelled unavailable. Rejected/ambiguous candidates do not auto-apply; cancellation and focus preservation work across the selected problem sequence.
- Source ideas: E15, E22, E23, E26.

## 1.3.0 — Artwork choice and offline workflows

Milestone: [1.3.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/5).

Add local/alternative artwork, explicit source policies, quality/language choices, and style scope.

<a id="r130-01"></a>

### R130-01 — Choose provider alternatives or a local poster

GitHub issue: [#21](https://github.com/AIBeCe/MovieFolderPosters/issues/21); milestone: [1.3.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/5).

- [ ] Scope: Separate artwork choice from confirmed movie identity. Validate explicitly selected local images and retain available source/attribution information without asserting an unknown license.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Changing artwork preserves identity and ownership protections. Invalid, oversized, moved, or missing local images fail safely; provenance is visible and credentials are never attached to image downloads.
- Source ideas: E48, E49, N29.

<a id="r130-02"></a>

### R130-02 — Support local-artwork and offline collection workflows

GitHub issue: [#22](https://github.com/AIBeCe/MovieFolderPosters/issues/22); milestone: [1.3.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/5).

- [ ] Scope: Recognize only approved local artwork names when enabled, define source precedence, and offer offline-only and strict-privacy collection policies plus credential-free local-artwork onboarding.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Offline policy is enforced at every host/Finder network entry point, including retries and manual actions. Tests prove zero remote requests, deterministic precedence, and safe local read scope. No local files are edited.
- Source ideas: N21, N25, N51, N52, N59, N71.

<a id="r130-03"></a>

### R130-03 — Select artwork by language and quality

GitHub issue: [#23](https://github.com/AIBeCe/MovieFolderPosters/issues/23); milestone: [1.3.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/5).

- [ ] Scope: Offer language/textless preferences and a minimum source-quality threshold with explicit fallback behavior. Unavailable artwork remains unresolved rather than silently generated or substituted.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Language fallback, absent textless artwork, poor resolution, and missing metadata yield explainable outcomes while preserving the selected movie identity.
- Source ideas: N22, N23, N24.

<a id="r130-04"></a>

### R130-04 — Add style scope and realistic previews

GitHub issue: [#24](https://github.com/AIBeCe/MovieFolderPosters/issues/24); milestone: [1.3.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/5).

- [ ] Scope: Add representative Finder-size previews and explicit global/collection/folder style precedence. Provide bounded immediate restyling of verified owned posters using cached sources where possible.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Preview output matches the production renderer. Style-only changes avoid metadata requests where a valid source exists; foreign/replaced icons, suppression, missing source, and cancellation are preserved.
- Source ideas: E43, E44, E45, E50.

## 1.4.0 — Reviewable batch work

Milestone: [1.4.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/6).

Build receipts, dry runs, finite queues, saved approvals, and undo in that dependency order.

<a id="r140-01"></a>

### R140-01 — Record exact mutation receipts and session summaries

GitHub issue: [#25](https://github.com/AIBeCe/MovieFolderPosters/issues/25); milestone: [1.4.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/6).

- [ ] Scope: Extend the operation model with bounded receipts of actual committed app-owned icon mutations and their identity/ownership evidence. Distinguish proposed, attempted, failed, and completed writes.
- Dependencies: 1.3 baseline; R100 outcome/event semantics.
- Acceptance: Interruption/concurrent process tests show receipts correspond to actual mutations. Retention is bounded and private; session summaries never infer changes from mere requests.
- Source ideas: N46, N49.

<a id="r140-02"></a>

### R140-02 — Preview changes without writing icons

GitHub issue: [#26](https://github.com/AIBeCe/MovieFolderPosters/issues/26); milestone: [1.4.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/6).

- [ ] Scope: Unify batch preview, dry run, metadata-only preparation, and side-by-side icon comparison. Show bounded resource estimates as estimates, recording the evidence and policies used.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Dry runs perform no icon writes. Metadata-only mode performs no poster download. Comparisons use the actual current icon and proposed renderer output; estimates are not scheduling or request-count guarantees.
- Source ideas: E27, N41, N42, N45, N86.

<a id="r140-03"></a>

### R140-03 — Run finite batches and explicit queues

GitHub issue: [#27](https://github.com/AIBeCe/MovieFolderPosters/issues/27); milestone: [1.4.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/6).

- [ ] Scope: Extend reviewed single-folder controls to selected roots/owned posters and a finite app-session queue. No automatic wake-up, persistent agent, polling, or silent restart of queued work.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Bounds, cancellation, queue teardown, stale configuration, duplicate selection, and foreign icons are covered by tests. Each queued job retains scoped authorization and relevant processing policy.
- Source ideas: E28, N48.

<a id="r140-04"></a>

### R140-04 — Apply reviewed plans and deferred approvals safely

GitHub issue: [#28](https://github.com/AIBeCe/MovieFolderPosters/issues/28); milestone: [1.4.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/6).

- [ ] Scope: Add saved plans, review-first policy, selected deferral, and an approval inbox inside focused operational sheets. Expire approvals when relevant evidence or policy changes.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Immediately before mutation, validate authorization, folder identity, ownership, suppression, policy, evidence, and approval validity. Finder entry points cannot bypass review-first policy.
- Source ideas: N43, N44, N47, N50.

<a id="r140-05"></a>

### R140-05 — Undo the latest eligible poster change

GitHub issue: [#29](https://github.com/AIBeCe/MovieFolderPosters/issues/29); milestone: [1.4.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/6).

- [ ] Scope: Use mutation receipts and retained prior icon state to reverse the latest eligible app mutation. Make retention and unavailable undo explicit; there is no unlimited icon-history promise.
- Dependencies: R140-01 and current ownership proof; R140-04 validation model.
- Acceptance: Undo rejects replaced folders, user-changed icons, missing prior state, expired evidence, and unsafe ownership transitions. Reversal changes only permitted custom-icon metadata.
- Source ideas: E30.

## 1.5.0 — Portability, maintenance, and recovery

Milestone: [1.5.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/7).

Protect user-confirmed decisions, validate imports, manage app-owned storage, and support safe migration.

<a id="r150-01"></a>

### R150-01 — Export portable configuration and confirmed decisions

GitHub issue: [#30](https://github.com/AIBeCe/MovieFolderPosters/issues/30); milestone: [1.5.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/7).

- [ ] Scope: Define a documented versioned export for settings, confirmed identity, local-artwork references, and explicitly selected source-image bundles. Keep transient cache separate from user decisions.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Round-trip fixtures preserve decisions. No credentials, raw bookmarks, ownership proofs, or implicit read permissions enter exports. User-selected image bundling has a clear scope and provenance.
- Source ideas: N4, N61, N62, N69, N70.

<a id="r150-02"></a>

### R150-02 — Review imports, mappings, and root relocation

GitHub issue: [#31](https://github.com/AIBeCe/MovieFolderPosters/issues/31); milestone: [1.5.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/7).

- [ ] Scope: Use one reviewed import pipeline for the neutral format, constrained CSV, and folder/movie/artwork mappings. Validate compatibility, conflicts, path remapping, and newly selected root permissions.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Malicious paths, stale identities, duplicate/conflicting mappings, missing artwork, and incompatible versions are rejected or explicitly resolved. Cross-Mac restore cannot transfer access grants or authorize overwriting an existing icon. The app does not relocate movie files.
- Source ideas: N5, N9, N14, N15, N27, N63, N64, N65, N66.

<a id="r150-03"></a>

### R150-03 — Maintain caches and remove app records deliberately

GitHub issue: [#32](https://github.com/AIBeCe/MovieFolderPosters/issues/32); milestone: [1.5.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/7).

- [ ] Scope: Distinguish cache cleanup, decision deletion, pre-uninstall export, and app-owned icon cleanup. Preview each operation scope; keep these separate actions rather than a single destructive reset.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Cache cleanup preserves confirmed matches and suppression; record deletion preserves installed icons; icon cleanup requires live identity/ownership validation. All operations preserve movie contents and foreign icons.
- Source ideas: E60, E69, N55, N99, N100.

<a id="r150-04"></a>

### R150-04 — Recover configuration and evolve stored data safely

GitHub issue: [#33](https://github.com/AIBeCe/MovieFolderPosters/issues/33); milestone: [1.5.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/7).

- [ ] Scope: Validate backups, offer reviewed recovery for damaged app settings, explain significant migrations, and retain bounded pre-upgrade decision snapshots without secrets or access grants.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Interrupted/failed/unsupported migrations retain recoverable originals. Recovery does not silently reset credentials, reauthorize roots, resurrect stale approvals, or replace existing folder icons.
- Source ideas: N95, N96, N97.

<a id="r150-05"></a>

### R150-05 — Document reusable service examples

GitHub issue: [#34](https://github.com/AIBeCe/MovieFolderPosters/issues/34); milestone: [1.5.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/7).

- [ ] Scope: Provide small opt-in examples for existing Network, FileSystem, and Persistence APIs after their contracts stabilize. This is a supporting developer-documentation track, not a new distributed product.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Examples compile independently, contain no secrets, request only their necessary permissions, and do not introduce application dependencies into services. This supporting track does not block the app release.
- Source ideas: N79.

## 1.6.0 — Advanced preferences without a policy engine by default

Milestone: [1.6.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/8).

Add reusable configuration only after the underlying settings and workflows are proven.

<a id="r160-01"></a>

### R160-01 — Introduce small reusable processing profiles

GitHub issue: [#35](https://github.com/AIBeCe/MovieFolderPosters/issues/35); milestone: [1.6.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/8).

- [ ] Scope: Unify named profiles, templates, inheritance, and policy copying around existing explicit settings. Show effective values and exceptions; copying never duplicates access grants or processing identity.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Precedence and edits are deterministic and testable. Imported/cloned settings cannot weaken ownership, privacy, review-first, or directory-scope constraints silently.
- Source ideas: N1, N2, N3, N6.

<a id="r160-02"></a>

### R160-02 — Group collections for bounded operations

GitHub issue: [#36](https://github.com/AIBeCe/MovieFolderPosters/issues/36); milestone: [1.6.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/8).

- [ ] Scope: Group existing configured roots as operation selections, without creating a hierarchical movie library or adding new filesystem scope.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Grouping does not register new roots, bypass disabled collections, or change folder identity. Group actions use existing finite queue and cancellation behavior.
- Source ideas: N7.

<a id="r160-03"></a>

### R160-03 — Retain bounded policy versions

GitHub issue: [#37](https://github.com/AIBeCe/MovieFolderPosters/issues/37); milestone: [1.6.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/8).

- [ ] Scope: Keep named policy snapshots with reviewable restoration, separate from movie decisions and installed icons.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Restoring policy does not replay old approvals, silently mutate icons, or transfer credentials. Retention and compatibility errors are explicit.
- Source ideas: N8.

<a id="r160-04"></a>

### R160-04 — Add constrained name-expansion dictionaries

GitHub issue: [#38](https://github.com/AIBeCe/MovieFolderPosters/issues/38); milestone: [1.6.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/8).

- [ ] Scope: Support explicit collection-scoped abbreviation expansions with original/transformed query previews. Do not introduce scripting or automatically treat a transformed query as verified movie evidence.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Conflicting/cyclic expansions are rejected; user corrections remain inspectable. Ambiguity checks still apply after transformation.
- Source ideas: N16.

<a id="r160-05"></a>

### R160-05 — Offer restrained matte-frame customization

GitHub issue: [#39](https://github.com/AIBeCe/MovieFolderPosters/issues/39); milestone: [1.6.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/8).

- [ ] Scope: After the three presets remain stable, investigate a small width range and contrast-tested frame palette inside Poster Layout. Preserve the accepted presets and defaults.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Production renderer and realistic previews agree at supported Finder sizes. Light/dark and contrast checks demonstrate legibility; changing customization does not affect identity or unowned icons.
- Source ideas: E46, E47.

## 1.7.0 — Optional macOS entry points and curated artwork

Milestone: [1.7.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/9).

Investigate native entry points one at a time and reuse existing safe operations. R170-04 is research-only.

<a id="r170-01"></a>

### R170-01 — Add native navigation and Finder entry points

GitHub issue: [#40](https://github.com/AIBeCe/MovieFolderPosters/issues/40); milestone: [1.7.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/9).

- [ ] Scope: Investigate a Finder toolbar command, Services add flow, supplied-artwork Quick Action, and navigation-only deep links. Reuse existing authorization, queue, and artwork pipelines.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Each entry point is accepted only after an AppKit/macOS prototype proves feasibility. No link or supplied URL can authorize a mutation; unavailable selection outside configured roots remains harmless.
- Source ideas: N35, N36, N39, N40.

<a id="r170-02"></a>

### R170-02 — Expose bounded Shortcuts operations and status

GitHub issue: [#41](https://github.com/AIBeCe/MovieFolderPosters/issues/41); milestone: [1.7.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/9).

- [ ] Scope: Investigate explicit Shortcuts processing and read-only status actions; no schedule or permanent helper is installed by this feature.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Actions preserve authorization, cancellation, privacy, review-first, and offline policy. Status queries cause no metadata requests. Unsupported interactions are documented, not emulated with a daemon.
- Source ideas: N37, N38.

<a id="r170-03"></a>

### R170-03 — Apply reviewed local artwork packs

GitHub issue: [#42](https://github.com/AIBeCe/MovieFolderPosters/issues/42); milestone: [1.7.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/9).

- [ ] Scope: Treat a user-selected pack as a constrained local image/mapping import through the existing review pipeline; never execute pack code or trust supplied paths.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Manifest/path traversal, missing assets, conflicting mappings, provenance, and ownership checks pass before any bounded apply. Packs never grant access or write movie-sidecar files.
- Source ideas: N28.

<a id="r170-04"></a>

### R170-04 — Evaluate a clearly non-movie fallback image

GitHub issue: [#43](https://github.com/AIBeCe/MovieFolderPosters/issues/43); milestone: [1.7.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/9).

- [ ] Scope: Research only: determine whether an explicitly opted-in neutral fallback helps users without hiding unresolved identity. It must never look like a confirmed movie match.
- Dependencies: R130 artwork policies and R140 review pipeline; research does not authorize fallback writes.
- Acceptance: A design review must demonstrate that unresolved state stays visible and confirmed/foreign icons cannot be overwritten. Ship only after separate scope approval; reject the feature if this cannot be achieved.
- Source ideas: N30.

## 1.8.0 — Evidence-based reports and optimization

Milestone: [1.8.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/10).

Use retained structured evidence for on-demand insight and measure reuse before optimizing it.

<a id="r180-01"></a>

### R180-01 — Report outcome patterns without becoming a library

GitHub issue: [#44](https://github.com/AIBeCe/MovieFolderPosters/issues/44); milestone: [1.8.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/10).

- [ ] Scope: Build bounded on-demand collection comparisons, source/rejection/ownership breakdowns, correction history, evidence-age views, and dated exports from structured records. Use focused reports, not a media dashboard.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Reports distinguish missing/incomplete/stale data and respect privacy/retention. Exported comparisons do not rename/reorganize files or apply matches. No periodic analytics scan is introduced.
- Source ideas: N67, N81, N82, N83, N84, N87, N88.

<a id="r180-02"></a>

### R180-02 — Measure and improve cache reuse across collections

GitHub issue: [#45](https://github.com/AIBeCe/MovieFolderPosters/issues/45); milestone: [1.8.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/10).

- [ ] Scope: Measure actual cache effectiveness before optimizing equivalent cross-root metadata queries. Bound reuse by provider, language, freshness, credentials, and relevant policy.
- Dependencies: Previous deliverable in this release; previous release baseline.
- Acceptance: Cross-root tests prove valid deduplication without stale identity reuse or cross-credential/private-data leakage. Statistics come from completed operations, not guessed request savings.
- Source ideas: E65, N85.

<a id="r180-03"></a>

### R180-03 — Compare policies using stored evidence

GitHub issue: [#46](https://github.com/AIBeCe/MovieFolderPosters/issues/46); milestone: [1.8.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/10).

- [ ] Scope: Evaluate two approved profile versions against retained evidence without applying either result. Surface incomplete evidence explicitly.
- Dependencies: R160 profiles/version snapshots and R140 dry-run validation.
- Acceptance: Comparisons make no icon writes and do not silently fetch missing evidence. Results preserve provenance and cannot be treated as live approval for a later mutation.
- Source ideas: N89.

## 2.0 candidates — Architecture and scope investigations

Milestone: [2.0 candidates](https://github.com/AIBeCe/MovieFolderPosters/milestone/11).

These are research candidates, not committed shipping requirements. Each needs evidence, a separate scope decision, and an implementation proposal. A failed feasibility study closes the candidate with a reason.

<a id="x200-01"></a>

### X200-01 — Research additional metadata providers and credentials

GitHub issue: [#47](https://github.com/AIBeCe/MovieFolderPosters/issues/47); milestone: [2.0 candidates](https://github.com/AIBeCe/MovieFolderPosters/milestone/11).

- [ ] Scope: Assess real coverage gaps, documented APIs, usage terms, provider capabilities, identity conflicts, and credential isolation before proposing another provider. Health comparison is user-invoked.
- Dependencies: Stable single-provider behavior and explicit new architecture/scope approval.
- Acceptance: A feasibility decision precedes design. No silent provider switching, identity merging, or credential sharing is allowed. Reject unsupported providers rather than creating fragile scraping integrations.
- Source ideas: N18, N56, N74, N75, N76.

<a id="x200-02"></a>

### X200-02 — Research edition-specific identity

GitHub issue: [#48](https://github.com/AIBeCe/MovieFolderPosters/issues/48); milestone: [2.0 candidates](https://github.com/AIBeCe/MovieFolderPosters/milestone/11).

- [ ] Scope: Determine whether available provider evidence can represent editions/cuts separately without inventing identifiers or breaking existing confirmed matches.
- Dependencies: R120 parsing/evidence and X200-01 if another provider is needed.
- Acceptance: Document evidence availability, migration, UI distinction, and identity conflicts. Keep edition parsing separate from a claim that edition identity is verified.
- Source ideas: N20.

<a id="x200-03"></a>

### X200-03 — Research a finite command-line interface

GitHub issue: [#49](https://github.com/AIBeCe/MovieFolderPosters/issues/49); milestone: [2.0 candidates](https://github.com/AIBeCe/MovieFolderPosters/milestone/11).

- [ ] Scope: Assess a user-invoked CLI including machine-readable dry runs, permission acquisition, secure credential access, packaging, and process coordination.
- Dependencies: R140 operations/plans and explicit distribution-boundary approval.
- Acceptance: A prototype demonstrates authorization and noninteractive failure behavior. CLI output contains no secrets or raw bookmarks and cannot bypass review-first/offline policy.
- Source ideas: N72, N73.

<a id="x200-04"></a>

### X200-04 — Research a narrow read-only integration API

GitHub issue: [#50](https://github.com/AIBeCe/MovieFolderPosters/issues/50); milestone: [2.0 candidates](https://github.com/AIBeCe/MovieFolderPosters/milestone/11).

- [ ] Scope: Justify a specific consumer before choosing transport and authentication. Keep queries read-only and local unless a separately approved architecture explicitly changes that boundary.
- Dependencies: Proven integration use case and separate security/architecture approval.
- Acceptance: Trust, authorization, information disclosure, lifecycle, and compatibility decisions are reviewed before exposing an endpoint. No always-running service is implied.
- Source ideas: N78.

<a id="x200-05"></a>

### X200-05 — Research explicitly bounded nested roots

GitHub issue: [#51](https://github.com/AIBeCe/MovieFolderPosters/issues/51); milestone: [2.0 candidates](https://github.com/AIBeCe/MovieFolderPosters/milestone/11).

- [ ] Scope: Evaluate an opt-in depth policy and its filesystem/identity/performance consequences. The current product remains immediate-child-only until this scope change is approved.
- Dependencies: Separate filesystem-scope approval; safe existing discovery and queue.
- Acceptance: Depth, total work, symlink, overlap, mount boundaries, permission scope, and cancellation limits are tested on an isolated prototype before changing normal discovery.
- Source ideas: N80.

<a id="x200-06"></a>

### X200-06 — Research constrained custom parser rules

GitHub issue: [#52](https://github.com/AIBeCe/MovieFolderPosters/issues/52); milestone: [2.0 candidates](https://github.com/AIBeCe/MovieFolderPosters/milestone/11).

- [ ] Scope: Assess a data-only, previewable rule format only after dictionaries/overrides prove insufficient. Do not silently introduce arbitrary code execution or unbounded regular-expression processing.
- Dependencies: R160-04 and demonstrated naming cases requiring more than explicit overrides.
- Acceptance: Rules have explicit bounds, invalid/conflicting rules fail safely, original inputs stay visible, and no transformation bypasses conservative matching.
- Source ideas: N17.

<a id="x200-07"></a>

### X200-07 — Research specific read-only media-tool import formats

GitHub issue: [#53](https://github.com/AIBeCe/MovieFolderPosters/issues/53); milestone: [2.0 candidates](https://github.com/AIBeCe/MovieFolderPosters/milestone/11).

- [ ] Scope: Select a concrete documented external export and map it into the neutral validated import pipeline. No media-tool commands, file organization, or continuous integration is included.
- Dependencies: R150 import/export and a specific supported external format.
- Acceptance: Format/version uncertainty, identifier conflicts, path handling, authorization, and data provenance are reviewed. Imported claims never become permission or icon ownership proof.
- Source ideas: N68.

<a id="x200-08"></a>

### X200-08 — Research explicit remote artwork URL import

GitHub issue: [#54](https://github.com/AIBeCe/MovieFolderPosters/issues/54); milestone: [2.0 candidates](https://github.com/AIBeCe/MovieFolderPosters/milestone/11).

- [ ] Scope: Assess whether local-image import is insufficient. Define image-origin, redirect, scheme, private-network, size, content-validation, and provenance rules before accepting user-supplied remote URLs.
- Dependencies: R130 artwork import, demonstrated need, and separate network security review.
- Acceptance: No provider credentials are sent to imported image hosts. Malformed/redirecting/oversized/private-network targets have reviewed failure behavior and cannot mutate icons before normal approval.
- Source ideas: N26.

## Conditional and supporting work

<a id="c01"></a>

### C01 — Unsaved-edit handling (E40)

There is no active task while controls save immediately. If an approved future feature introduces draft edits,
its own proposal must define apply/discard/cancel and protect against accidental loss. This is a conditional
requirement, not a forgotten idea or permanent rejection. It becomes part of the first feature that needs it.

R150-05 is a supporting developer-documentation track, not an application-release prerequisite. R170-04 and all
X200 entries require investigation decisions, not implementation merely to satisfy catalogue coverage. No idea
is permanently rejected at this documentation stage; a later rejection must preserve its ID and evidence.

## New UI proposals and scope boundaries

The ten U-series proposals in [UI enhancements](UI_ENHANCEMENTS.md) are additions to the original 180 inputs.
They map into the release deliverables rather than adding ten separate product subsystems. Main stays a compact
collection table; results and approvals use focused sheets. Settings retains native preference panes and visual
choices; Log remains a structured operational table. No permanent fourth window, sidebar, library, or UI redesign
is authorized by this roadmap.

## Ownership and implementation workflow

| Responsibility | Existing owner / starting locations |
| --- | --- |
| Native windows, navigation, presentation | AppCoordinator; feature-owned ConfigurationCoordinator, LogCoordinator, MoviePosterActionCoordinator; their view controllers and view models |
| Release-name parsing | Packages/MovieFolderParsing; Foundation-only grammar and tests, no movie identification |
| Folder policy, outcomes, matching, retries | MovieFolderProcessor, MovieMatcher, MoviePosterActionService and shared application source |
| Finder integration and invocation | MovieFolderPostersFinder/Integration/FinderSync.swift, shared configuration/request code |
| HTTP, provider decoding, bounded downloads | Packages/Network; no filesystem writes or movie-match decisions |
| Scope, identity, icon operations, local images | Packages/FileSystem; no metadata-provider requests |
| Versioned records, leases, durable primitives | Packages/Persistence; application code owns retention and processing policy |
| Credentials, configuration, cross-process sharing | Existing DirectoryConfigurationService, Shared configuration repository, KeychainCredentialStore |

Starting locations are navigation aids, not approval of particular new APIs or storage schemas. Inspect actual
code before each proposal; reuse existing contracts. Large deliverables must be decomposed into bounded points,
one failing-behavior test cycle at a time. Propose concrete code at that stage, not years of speculative types now.

For each point: inspect -> propose code/tests -> approval -> failing meaningful test -> minimal implementation ->
focused verification -> independent review where material -> update evidence -> commit approved work -> integrate
with `git merge --ff-only` into develop. Use feature/* from develop and bugfix/* for unreleased fixes. Stop on
history divergence rather than rewriting it. Push, release/*, main, version tags, signing publication, and later
product work require their applicable explicit authorization. No release branch or tag is created by these docs.

Use unit tests for decisions and failures, package tests for services, integration tests for coordination and
persistence, and native/manual checks for Finder callbacks, sandbox authorization, rendering and icon persistence.
Do not claim a passing test harness proves an unperformed native workflow.

## Platform and provider references

- Apple's [Finder Sync guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html)
  documents observation callbacks, duplicate-window behavior, separate extension processes, and context actions.
  Observation does not establish general continuous filesystem monitoring or authorization.
- TMDb's [rate-limit guidance](https://developer.themoviedb.org/docs/rate-limiting) requires respect for throttling;
  do not hardcode an assumed permanent public requests-per-second entitlement.
- TMDb's [FAQ](https://developer.themoviedb.org/docs/faq) documents attribution and usage distinctions. Recheck the
  applicable distribution/usage setup before release; this roadmap does not select a commercial model.
- [Semantic Versioning](https://semver.org/) informs patch/minor/major compatibility decisions.

References checked 2026-10-16. Revalidate time-sensitive provider/platform requirements at implementation/release.

## Current handoff

R100-01 and R100-02 are complete; GitHub issues #1 and #2 are closed as completed. Both were fast-forward
integrated into `develop`, and their feature branches were deleted. `develop` was pushed to GitHub through
`b48d44d` on 2026-10-18. No release was published.

R100-02 implementation is `049b74b`; [Processing results](COLLECTION_PROCESSING.md) records the approved
scope, independent review, tests, builds, compatibility evidence, and unperformed native qualification.
The subsequent extension-registration cleanup retained the active Xcode Debug copy and removed obsolete
build copies; PluginKit and LaunchServices were verified to contain one current app/extension pair.

R100-03 is committed as `e7d404b` and integrated into `develop`, with the MovieFolderCommon and Log package
extraction described in [Common and Log migration](COMMON_AND_LOG_MIGRATION.md). GitHub issue #3 remains open.
R100-04 / issue #4 is implemented and verified locally under the user's subsequent full-feature authorization.
[Processing recovery](PROCESSING_RECOVERY.md) records the safety policy, controlled tests, independent review,
coverage, native builds, and remaining platform qualification limits. Recovery commit `008a6f3` is integrated
into local `develop`; issue closure, later issues, and publication remain outside the completed local work.
