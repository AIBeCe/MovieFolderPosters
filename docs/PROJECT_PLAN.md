# Movie Folder Posters — Project Plan

Status: Approved. Implementation requires separate approval for each point.

> Release planning now lives in [Versioned production roadmap](PRODUCTION_ROADMAP.md), with complete
> [idea triage](IDEA_TRIAGE.md) and [native UI enhancements](UI_ENHANCEMENTS.md). This document retains the original
> Phase 1–7 architecture and dated evidence. Do not interpret historical phase status as current release qualification.
> Documentation approval does not authorize the next implementation point.
> Release milestones and deliverable issues are indexed in [GitHub tracking](GITHUB_TRACKING.md).

## Main goal

Display movie posters as native folder icons in Finder instead of generic folder icons.

Finder remains the movie browser.
Folder names and movie contents remain unchanged.
Assigned icons must persist independently of the application and extension.

## Development approach

- Follow AGENTS.md.
- Use SOLID principles as much as possible.
- Start with the smallest useful behavior and add complexity only when needed.
- Work through one implementation point at a time.
- Inspect existing behavior before presenting proposed changes.
- Present actual proposed code, affected files, decisions, and verification.
- Wait for explicit approval before implementation.
- Use TDD wherever meaningful: failing behavioral test, minimum implementation, refactor.
- Use integration or manual verification for OS behavior that unit tests cannot establish.
- Record meaningful decisions, results, limitations, and remaining work in this document.
- Approval of this plan does not authorize further product implementation.

## Architecture

The application coordinates in-process services provided by local SPM modules.

### Network

Owns requests, response decoding, poster downloads, and network error handling.
Returns data without writing files.
Does not own movie matching decisions, credential storage, or UI.

### FileSystem

Owns filesystem authorization, security-scoped access, directory enumeration,
file operations, and native custom folder icon operations.
Does not perform networking or decide which movie matches a folder.

### Persistence — introduced when needed

Owns durable record storage, retrieval, schema changes, and storage integrity.
The application owns cache expiration, retry, and processing policies.
Downloaded image files are managed through FileSystem.

### Application-specific behavior

Keep release-name parsing, movie matching, processing decisions, and configuration
in the application code.

Use AppKit and MVVM-C for the configuration interface.
Keep the Finder Sync target responsible for registration and lifecycle integration.

The extension cannot import the host executable.
When processing is needed in both targets, share the necessary application-specific
source through target membership initially. Do not introduce another package by default.

### Dependency rules

- Services do not depend on the application.
- Add dependencies between services only when justified by a demonstrated need.
- Prefer Apple frameworks and the fewest possible third-party SPM dependencies.
- Introduce packages when an approved implementation point needs them.
- Do not create empty packages or general-purpose framework infrastructure.
- SPM boundaries do not grant sandbox permissions; entitlements belong to each process.

## Existing baseline

- AppKit template host and test targets exist.
- Finder Sync extension is embedded in the host.
- One hardcoded TestMovies directory is registered.
- Initialization and begin/end observation callbacks are logged.
- Signed Debug build, signature checks, and embedded-extension validation passed.
- The signing blocker was resolved after refreshing the Xcode account and allowing automatic signing.
- Finder extension recognition, enablement, and lifecycle callbacks were verified on the development Mac.
- No poster assignment or service packages exist yet.
- AGENTS.md is established.
- Git branch: feature/finder-lifecycle.
- The public GitHub repository contains initial commit f52c8f7 on main, develop, and feature/finder-lifecycle.

## Phase 1 — Complete Finder Sync validation

### 1.1 Signing and extension loading

Inspect the signing configuration and propose the smallest necessary correction.

Acceptance:

- Signed host and extension build successfully.
- macOS recognizes the extension.
- The extension can be enabled.

### 1.2 Observation behavior

Use the existing TestMovies directory and lifecycle logging.

Verify:

- Opening, closing all views, and reopening the directory.
- Multiple Finder windows showing the same directory.
- Subdirectory observation.
- Separate extension instances used by Open/Save dialogs.

Acceptance:
Document actual callbacks and their limitations.
Do not assume callbacks provide filesystem change notifications.
Stop before processing if the intended trigger cannot be demonstrated.

## Phase 2 — One folder, one local poster

### 2.1 Introduce the File service and validate access

Create the local File package with only the API needed by this phase.
Establish supported authorization for the isolated test directory.

A minimal permission-selection control may be necessary.
Do not build the complete configuration interface yet.

TDD:
Test authorization-related decisions that can be exercised independently.

Integration:
Demonstrate actual sandbox access from the extension process.

Acceptance:
Permission acquisition and scoped-access lifetime are understood.
No sandbox disabling or helper service is introduced without a separate proposal.

### 2.2 Assign a local poster to one explicit test folder

Bundle a test image.
Operate on one explicitly named immediate child of TestMovies.
Preserve existing custom icons and reject symbolic-link targets.

Keep image preparation and custom-icon assignment inside File.
Preserve poster proportions without stretching.

TDD:
Test image preparation and target validation where independently testable.

Integration:

- Finder visibly displays the poster.
- Check multiple icon sizes and relevant view modes.
- Restart Finder and terminate the extension to check persistence.
- Verify folder names and movie contents remain unchanged.
- Record custom-icon metadata changes and refresh behavior.

Acceptance:
Opening the test root can trigger persistent icon assignment through the extension.
Only this result establishes the first functional milestone.

## Phase 3 — Simple release-name parsing

Keep the parser in application-specific code, independent of Finder and networking.

Start with straightforward title/year examples.
Add release metadata and ambiguous cases incrementally.

TDD:

- Title and year extraction.
- Names without a year.
- Legitimate numbers and technical-looking words in titles.
- Ambiguous year tokens.
- Realistic source, resolution, codec, and audio suffixes.

Use full folder names as fixtures, not truncated screenshot labels.

Acceptance:
Supported behavior is deterministic; uncertain names are not silently guessed.

## Phase 4 — Network service and conservative matching

Status: completed on 2026-10-11 on `feature/tmdb-matching`. Independent review: PASS.

### 4.1 Introduce Network

Implement the minimum TMDb search and poster-download APIs.
Supply credentials without hardcoding or committing secrets.

TDD:
Use controlled transport responses to test decoding, empty results, malformed data,
authentication errors, rate limits, download failures, and cancellation.

Acceptance:
Network operations are testable without live TMDb requests or filesystem writes.

### 4.2 Match movie candidates

Keep matching policy in application-specific code.
Propose the exact rules before implementation.

Start with conservative title/year agreement.
Add scoring, alternate titles, or additional requests only when examples justify them.

TDD:

- Clear unique matches.
- Identical titles with different years.
- Conflicting title/year evidence.
- Multiple plausible candidates.
- Missing posters and no suitable result.

Acceptance:
Ambiguous results remain unresolved.
The first search result is not automatically accepted.

Implementation:

- Added the local Network SPM service with injectable transport, TMDb decoding, and in-memory poster retrieval.
- Credentials are injected in memory; no secret is saved, logged, or committed. Persistent credential UI/storage
  remains configuration work. This phase was tested without live credentials or live TMDb requests.
- Added application-specific exact normalized title/original-title and exact optional-year matching.
- Incomplete searches and ties remain unresolved; missing posters do not break identity ties.
- Network's 39 cases and matching's 25 cases pass. Added a reproducible application matching harness.
- Reviewed and verified URLSession cleanup, cancellation, redirect rejection, image validation, and pagination.
- Linked Network to the host and unit tests, enabled host outgoing-network sandbox access, and compiled with Swift 6.
- Signed normal and test builds passed; final signature and outgoing-network entitlement checks passed.
- No Finder processing, persistent caching, filesystem writes, or Phase 5 work was added.

See [Network and matching](NETWORK_MATCHING.md) for APIs, rules, verification, and limits.

Integration note: Phase 2 is committed separately on `feature/folder-access` (e53ab10), and Phase 3 on
`feature/release-name-parser` (519879a). This feature was created from develop. Integration of those branches
remains separate work; this phase does not merge or push them.

## Phase 5 — Persistence and automatic processing

Status: implemented and verified with controlled metadata responses. Live TMDb credential setup and
arbitrary directory authorization remain outstanding; no production account verification is claimed.
See [AUTOMATIC_PROCESSING.md](AUTOMATIC_PROCESSING.md) and
[PHASE_5_VERIFICATION.md](PHASE_5_VERIFICATION.md) for policy and executed evidence.

### 5.1 Introduce Persistence

Define the minimum records needed for processed folders, movie identity,
poster references, and unresolved results.

Approved storage: a local Persistence package with versioned opaque records, atomic writes, and
nonblocking cross-process leases. Filesystem descriptors pin record access against path replacement.
No database or external dependency is needed. Folder records retain identity fingerprints, status,
retry dates, and matched movie identifiers/poster paths; query records retain conservative search results.

TDD:
Test saving, reopening, updating, missing records, and invalid stored data.
Test schema migration only when a schema change is introduced.

Acceptance:
Records survive application and extension termination.
Multiple-process access requirements are addressed explicitly.

### 5.2 Connect the workflow

Finder observation → enumerate immediate children → skip unchanged processed folders
→ parse → match → download → assign icon → persist result.

The application coordinates Network, FileSystem, and Persistence. The extension compiles the same
application-specific processor, parser, and matcher. Processing uses one candidate at a time and a
cross-process root lease. Existing custom icons are preserved without metadata requests or icon writes.
Missing icons can be restored from cached posters; ambiguous matches remain unresolved.

Query and unresolved-result lifetimes are 24 hours; transient folder failures retry after ten minutes.
Authentication errors defer the root for 24 hours; rate-limit delays honor Retry-After within one minute
to 24 hours. Removed folder records and expired queries are pruned on observation. Cached poster files
are retained without a separate eviction service. Cancelled work does not persist a negative result.

Debug Finder verification uses explicitly enabled deterministic responses through TMDbClient. Phase 6 adds secure
credential configuration; Release always uses live transport and never the development fixture.

TDD:

- Ignore files, hidden entries, symbolic links, and deeper descendants.
- Preserve unrelated custom icons.
- Avoid redundant requests and icon writes.
- Bound concurrency and deduplicate work.
- Handle cancellation, partial failures, and unavailable volumes.
- Avoid repeated requests for unresolved matches.

Integration:
Start with a few fixtures, then increase collection size.
Measure initial processing and repeat visits.

Acceptance:
Finder stays responsive and repeat visits perform minimal work.
All operations remain within authorized configured directories.

## Phase 6 — Minimal AppKit configuration

Status: completed and independently reviewed on 2026-10-12 on `feature/directory-configuration`.
Signed Debug and Release builds passed. Native folder selection, shared Data Protection Keychain access,
Finder poster assignment, persistent extension-owned authorization after restart, repair, and removal passed.
Configuration tests passed 16/16 in both Debug and Release; view-model tests 5/5 and UI launch test 1/1 passed.
See [Directory configuration](DIRECTORY_CONFIGURATION.md) and [Phase 6 verification](PHASE_6_VERIFICATION.md).
Live TMDb credentials, reboot, and physical external-volume recovery remain unverified.


Replace the template interface with programmatic AppKit using MVVM-C.

Provide monitored-directory management and necessary credential configuration.
Share configuration with the extension using a mechanism proposed and validated separately.

TDD:
Test presentation state, configuration persistence, directory removal,
stale authorization, and unavailable volumes.

Acceptance:
The host remains a configuration utility, not a movie browser.

## Phase 7 — Optional manual Finder actions

Status: completed and independently reviewed on 2026-10-12 on `feature/finder-actions`.
Added direct Finder commands and minimal host confirmation windows for refresh, movie selection, removal, and TMDb.
FileSystem ownership proofs preserve foreign/replaced icons; durable suppression prevents automatic reassignment.
Stable cross-process root coordination and a current-configuration lease fence manual mutations after network waits.
Native refresh, removal, and explicit selection passed with controlled metadata responses and unchanged movie bytes.
All focused suites, final signed Debug/Release builds, signature checks, and test compilation passed.
See [Finder actions](FINDER_ACTIONS.md) and [Phase 7 verification](PHASE_7_VERIFICATION.md) for evidence and limits.
No merge or push was performed. Further product work requires a new authorization.


Propose individual actions only after automatic processing is stable:

- Refresh poster.
- Select a different movie match.
- Remove an application-assigned poster.
- View the movie on TMDb.

Removal must preserve unrelated custom icons.

## Evidence and stop points

For each implementation point, record:

- Approved scope and decisions.
- Automated verification and results.
- Observed Finder behavior.
- Failed, blocked, and unperformed checks.
- Limitations and remaining work.

If platform evidence invalidates the preferred architecture, stop and explain it.
Propose the smallest adjustment before adding processes or services.

Do not claim completion until Finder displays a persistent movie poster
through the intended extension workflow.

## Phase 1 verification — 2026-10-11

Status: Passed on the current development Mac.

- Automatic-signing build and signature validation passed.
- macOS recognized and enabled the sandboxed Finder Sync extension.
- Finder open/close/reopen and subdirectory callbacks were observed.
- Duplicate windows did not produce additional begin-observation callbacks.
- Open/Save dialogs received callbacks in a process separate from Finder.
- The tested Open/Save dialogs reused the same extension process.
- User paths remained private in diagnostic logs.
- No product code changes were required.
- Filesystem write access and persistent custom icons remain unverified.
- Next proposed work: Phase 2.1, File service and authorized directory access.

## GitFlow integration — 2026-10-12

All completed Phase 1–7 feature branch tips are ancestors of local develop.
The final reviewed Phase 7 implementation was merged with a non-fast-forward merge.
Its earlier source dependencies were already included, so older feature histories were merged while preserving
that tested tree instead of reintroducing obsolete configuration code. Exact tree equality was verified afterward.
The agent rules now make merge into develop part of approved feature completion. Subsequent feature branches
start from updated develop. Main and remote branches were not changed; no push was performed.

## Poster appearance feature — 2026-10-13

Approved scope: a global Raw / Soft finish / Matte frame selector, with Soft finish as the migration and new-install
default. FileSystem owns native bitmap styling and verified icon ownership; the main target owns settings and
movie processing. Cached sources restyle owned icons without invalidating matches or making network requests.
Foreign icons, suppression, missing source images and explicit movie selections are preserved.

Implemented on `feature/poster-appearance`; independent review passed after correcting a removal/suppression
race in automatic restyling. FileSystem 44, processing 40, configuration 20 and UI eight tests passed. Final signed
Debug/Release builds, complete bundle signature checks, and all Xcode test-target compilation passed.
The verified feature is committed and merged into local develop using a non-fast-forward merge; no push was performed. Native UI automation timed out; live selector interaction and Finder appearance checks are
unverified. See [Poster appearance](POSTER_APPEARANCE.md) for decisions and verification limits.
