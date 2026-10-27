# Finder result utilities — R110-04

Status: Implementation approved and committed as `e2cf2eb` on 2026-10-27.
The user explicitly authorized issue-scoped Validation Phase; validation corrections remain uncommitted for review.
Issue: https://github.com/AIBeCe/MovieFolderPosters/issues/13
Branch: `feature/finder-result-utilities`, based on `develop` at `b59be2b`.

## Authorization and lifecycle

The user approved the initial implementation and subsequently reviewed naming point by point. The approved
shared names are `MovieFolderContextMenuAction` and `MovieFolderContextMenuRequest`. Approval authorizes implementation and focused coherence
checks only. Do not commit, merge, push, close the issue, register an extension, or start formal Validation Phase.
Formal Validation Phase was separately authorized and includes verification, issue-scoped tests, SwiftLint,
and Swift style review. Implementation review is required; preserve the same Worker and Reviewer through fixes.

## Approved design

Finder remains the browser. Preserve programmatic AppKit, Swift 6, MVVM-C, local service boundaries, existing
poster actions, movie contents, and existing persistence formats. No new dependency, module, watcher, daemon,
polling, live provider request, automatic migration, or icon mutation belongs to these utilities.

### Finder commands

Group every MovieFolderPosters Finder command beneath one **Movie Folder Posters** submenu. Inside it, remove
the redundant `Movie Poster:` title prefix. For one visible authorized immediate child, offer:

1. Inspect Results…
2. Copy Verified Movie Title…
3. Copy TMDb Identifier…
4. Separator
5. Refresh Poster… / Change Movie Match… / Remove Poster… / View on TMDb…
6. Separator
7. Ignore Folder… or Include Folder…

One configured collection root offers only Inspect Results…. Reject files, hidden children, nested descendants,
unrelated locations, and multiple selections. Preserve principal-object dispatch and expiring unique scalar tags.
Capture identity at menu construction; never retarget an expired item to a newer selection.

### Shared request

Add `MovieFolderContextMenuAction: String, Sendable, CaseIterable` with `inspect`, `copyMovieTitle`, and
`copyMovieIdentifier`. Add `MovieFolderContextMenuRequest: Sendable, Equatable` with root UUID, a collection/child
target enum, and action. Collection targets only permit inspect. Child targets carry name and identity, never
an arbitrary path, title, movie ID, credential, or bookmark.

Use `moviefolderposters://results` with exactly `root` and `action` for a collection, or exactly those fields plus
`child` and `identity` for a child. Reject duplicate/unknown/missing fields, wrong route/scheme, path/user/password/
port/fragment, invalid UUID/action, invalid target combinations, hidden/path-like/control-containing child names,
and empty/control-containing identities. Limits: complete URL 4096 UTF-8 bytes, child name 255 bytes, identity
256 bytes. Use throwing validated construction and `makeURL() throws -> URL`; no force unwraps.

Receiving any URL only opens UI. Finder Copy commands focus the corresponding button in inspection; explicit
host Copy is still required. A custom URL must never overwrite the clipboard automatically.

### Inspection

Reuse Processing Details, not the poster-action window or only Unresolved Results. A root request shows the
existing collection report. A child request focuses that folder, including successful, unresolved, excluded,
preserved, or suppressed records. Show missing assessment honestly when the live child has no saved record.
Show current pause/inclusion/matching configuration separately from saved suppression/identity evidence.
Keep stale, missing, partial, busy, unreadable and migration guidance explicit; do not manufacture outcomes.

Introduce `CollectionProcessingDetailsViewModel` observing the existing summary publisher with weak delegates.
Do not retain the old immutable-summary limitation for this live sheet. Add the two Copy buttons for child
inspection. Opening/reloading the sheet must never search, retry, repair, migrate, or change an icon.

Reuse an inspection of the same target. A new request may replace idle inspection. Preserve unrelated attached
sheets or active operations and show safe close-current-sheet guidance. Closing, cancellation, configuration
change and request replacement invalidate pending effects by generation. No late effect may escape its owner.

### Authorization and service boundaries

Extract only the existing bookmark/root authorization acquisition from `MoviePosterActionService.withAuthorizedRoot`
into host-local `Features/FolderUtilities/MovieFolderAuthorization.swift`. Keep root-first acquisition separate
from child checking so root inspection works. Preserve private-bookmark recovery, overlap rejection, path/root
identity checks, root security scope and authorization-store access lifetime. Existing poster actions keep their
own child checks, recovery/provider composition, suppression/ownership/mutation checks and current behavior.

Create a narrow host utility service independent of processing/provider admission. Use neutral
`ConfigurationRepository.readHoldingAccess()` for the final settings fence, never the icon-change policy API.
Reuse the exact context comparison already in `CollectionSummaryService.matches`; do not duplicate freshness
semantics. Relevant equality includes root/authorization/processing configuration, credentials revision, fixtures,
appearance, matching configuration, and root overlap. A matching context can contain partial/interrupted/failed
folder outcomes; it is not equivalent to displayState == current.

Prepare effects away from UI callbacks. Retain root authorization, security scope, final configuration lease,
and (for Copy/Reveal) root processing coordination access through the immediate MainActor platform call.
Do not return bare URLs/text after releasing authorization. Reject contention safely. Follow existing lock order:
root coordination → current configuration → short processing-record access. Do not hold state-record access
across awaits. No provider/network await occurs in utility work. Prepared effects are transient, not retained as
view-model state. Immediately before performing them, check task cancellation and UI generation without another
intervening await. Strongly retain safety collaborators; optional weak delegates must not control admission.

### Copy

Allow Copy only for currently authorized, physically matching child folders with current-context saved evidence,
a positive movieID, recorded movieIdentitySource and assessedAt. Do not require Done or owned poster: a verified
movie can survive artwork failure. Copy Title requires a nonempty whitespace-trimmed saved movieTitle; never use
parsed name or Untitled. Copy Identifier requires no title and writes the decimal TMDb ID. Do not support other
external IDs or request provider metadata. Read current evidence again at invocation, independently of button state.
Stale/missing/unreadable evidence does not permit Copy. Paused/excluded/suppressed status alone is not a processing
admission requirement for these read-only utilities, although the saved context still has to match.

Add `VerifiedMovieDetails` as a testable projection and an injected main-actor platform boundary. The live adapter
uses NSPasteboard and NSWorkspace. Validation failure leaves clipboard untouched; report actual clipboard write
failure separately. Do not log copied text, user paths, bookmarks or credentials.

### Reveal

Add **Reveal Selected in Finder** to Unresolved Results. Capture exactly the selected visible row name/identity
pairs in natural display order. Require 1–32 rows and identity evidence for every row. Never expand to all rows,
or silently filter an invalid row into a smaller successful selection. Revalidate all captured selections against
saved unresolved membership and current authorized filesystem identity. Stale processing evidence alone need not
prevent Reveal when the selected folders still match. Missing/replaced/no-longer-unresolved/unauthorized folders
reject the entire effect. Call `NSWorkspace.activateFileViewerSelecting` once for the complete validated selection.
Disable selection/filter changes and conflicting actions during finite validation; close/cancel prevents late Reveal.
Finder path-based selection cannot be made atomic against unrelated filesystem changes after validation.

## Implementation plan

> For agentic workers: apply superpowers:subagent-driven-development, TDD where meaningful, and swift-style-guide.

**Goal:** Implement all four approved utilities with a grouped Finder submenu and fresh authorization.
**Architecture:** Typed shared request, host-only authorization extraction and utility service, existing AppKit
details/results presentation, explicit clipboard/Finder effects with retained leases.
**Tech stack:** Swift 6, programmatic AppKit/Finder Sync, MovieFolderCommon, FileSystem, Persistence, Swift Testing.
**Spec:** Approved design above, reflecting the conversation's complete proposal and final naming/menu approvals.

### Task 1: Complete connected R110-04 implementation

Ownership: one Worker owns product sources, related tests and any required harness discovery edits. Root owns this
plan/document and final scope decisions. The Worker is not alone and must preserve edits made by others.

Known files/components:
- Common `FinderIntegration/MoviePosterRequest.swift` is the existing strict request reference; add the new request
  alongside it, without changing the existing poster request invariant.
- Finder `Integration/MovieFolderContextMenuHandler.swift`, `FinderSync.swift`, and `FinderIntegrationTests.swift` own menu
  validation, tags, principal dispatch and fake platform behavior.
- Host `Features/PosterActions/MoviePosterActionService.swift` owns the private root-access helper to extract.
- Host `Features/Collections/CollectionSummaryService.swift` owns freshness comparison and weak summary publication.
- Host `CollectionProcessingDetailsViewController.swift`, new details view model, `ConfigurationCoordinator.swift`,
  `CollectionResultsViewModel.swift` and `CollectionResultsViewController.swift` own sheet/report/Reveal integration.
- `Application/AppDelegate.swift` and `AppCoordinator.swift` own routing and service composition.
- New `Features/FolderUtilities` files own authorization, utility service, platform, prepared effects and identity
  projection. Use responsibility-based files rather than a catch-all file or speculative package.
- Mirror tests under the owning host/Common/Finder test directories; source discovery is in
  `scripts/test-support/prepare-application-harness.py` if explicit inclusion must be updated.

Required interfaces: shared `MovieFolderContextMenuAction` and `MovieFolderContextMenuRequest`; existing summary publisher
and details controller extended through a `CollectionProcessingDetailsViewModel`; narrow injected host utility
service and main-actor platform protocol. Internal concrete signatures may follow existing conventions, provided
the exact approved behavior, scope, lifetime/fencing, and naming are preserved.

- [ ] Write focused failing request/menu/identity tests before the corresponding production changes; record RED.
  Evidence limitation: request missing-API RED and the later wording regression RED were captured. Menu/utility
  tests were added during implementation without separate preimplementation RED captures; full TDD provenance
  is not claimed. The behavioral tests and their passing implementation checks are recorded below.
- [x] Implement bounded request, grouped root/child Finder menu and principal dispatch; preserve old action tags.
- [x] Extract root authorization without changing poster mutation behavior; add utilities with scoped prepared effects.
- [x] Implement current-context Copy admission, explicit platform calls and the full-selection Reveal admission.
- [x] Integrate dynamic focused details, routing, explicit Copy focus, Reveal button/selection and cancellation.
- [x] Run directly affected Common request, Finder integration, host utilities/collections/coordinator and poster
  regression suites; capture logs and concise counts. Use existing harnesses with test filters. No full project suite.
- [x] Complete independent review and resolve all Critical/Important findings with the same Worker/Reviewer pair.
- [x] Record implementation evidence, limitations, and remaining formal/native checks here.
- [x] Commit implementation after explicit Implementation Phase approval (`e2cf2eb`).

## Review focus

- Forged/malformed custom URLs open at most validated presentation and never write clipboard or mutate icons.
- A replacement root/child or concurrent settings/processing change cannot inherit old copy/reveal admission.
- Authorization and final settings/coordination access survive through the actual platform invocation.
- Partial/failed but verified movie identity remains copyable; stale/unconfirmed identity never becomes confirmed.
- Closing/replacing sheets or changing configuration prevents late clipboard/Finder actions and preserves unrelated UI.

## Evidence and progress

Implementation checks, distinct from formal validation:

| Check | Result | Local evidence |
| --- | --- | --- |
| Shared request contract | 2 Swift Testing tests passed | `/private/tmp/R110-04-request-green.log` |
| Focused host/Finder integration and poster regression | 57 tests in 6 suites passed | `/private/tmp/R110-04-focused-final.log` |
| Final occupied-sheet coordinator guard | 6 coordinator tests passed | `/private/tmp/R110-04-coordinator-final.log` |
| Review follow-ups: results, controller and utility behavior | 28 tests in 3 suites passed | `/private/tmp/R110-04-review-followup.log` |
| Independent implementation review | PASS; no Critical/Important findings | Same Worker/Reviewer ownership retained |
| Scoped follow-up review | PASS; N1/N2 resolved, no new findings | Same Reviewer, 2026-10-27 |
| Git whitespace check | Passed | `rtk git diff --check` |

The runs overlap; counts must not be added as distinct tests. The later 28-test run covers the final wording
change and added Reveal tests; other product code remains at the reviewed 57-test integration checkpoint.
An initial complete harness compilation reported existing weak-mutability warnings; final incremental focused
logs had no warnings/errors. No full project test suite was run.

Request missing-API RED evidence is `/private/tmp/R110-04-request-red.log`; the later stale-guidance regression
RED is `/private/tmp/R110-04-review-wording-red.log`. These do not establish a preimplementation RED cycle for
every new behavior.

### Integration and review decisions

- Cold-launch Finder routing awaits coalesced configuration loading rather than dropping the first request while
  Main loads. `ConfigurationViewModel.load()` now awaits its existing load task for this directly affected path.
- Same-target inspection reuses its sheet and honors updated Copy focus. Occupied-sheet checks include retained
  coordinator-owned windows because headless AppKit can report the child's `sheetParent` while the parent's
  `attachedSheet` remains absent. Automated tests assert the owned child-sheet relationship.
- N1 narrowed stale-result guidance to Choose Movie/Retry and explains that Reveal revalidates selected folders.
- N2 adds connected results-view-model → real utility admission → injected platform tests for exact natural-order
  Reveal and suppression of noncooperative late preparation after close or configuration cancellation. Tests also
  verify that settings access is still held at the actual platform boundary.
- Swift style was applied during implementation/review. The final wording received an apple-design writing
  component review. Neither substitutes for formal style validation or actual rendered UI inspection.

The approved implementation is committed on `feature/finder-result-utilities`. Unrelated `.DS_Store`, Xcode user data,
and MovieFolderParsing `.swiftpm` files remain preserved. The Xcode project references the renamed contextual-menu
handler; the synchronized host group and existing harness discover the new feature/test folders automatically.

Formal validation and SwiftLint evidence are recorded below. Native Finder registration and live provider runs
have not been performed for R110-04. Native Finder-to-host activation, clipboard behavior, keyboard/VoiceOver, and Finder selection require
separate recorded observations and are not implied by automated results.

## Approved naming corrections — 2026-10-27

The contextual-menu naming audit and implementation were explicitly approved. Use
`MovieFolderContextMenuAction`, `MovieFolderContextMenuRequest`, and `MovieFolderContextMenuRequestError`
throughout shared request construction, parsing, host consumers, and tests. The wire route and action raw values
remain compatible.

`MovieFolderContextMenuHandler` owns menu construction and captured-request dispatch. Its selection, settings,
and host-opening collaborator is `MovieFolderContextMenuEnvironment`, implemented by
`LiveMovieFolderContextMenuEnvironment`. This responsibility distinction corrects the earlier proposal that
misidentified the native adapter as the menu builder. Menu callbacks, captured-request dictionaries, tag counters,
selection lookup, test doubles, file references, and diagnostic categories use ContextMenu terminology.

Host coordinators expose `showProcessingDetails(for:)`. After loading configuration,
`showLoadedProcessingDetails(for:)` preserves existing sheet reuse and occupancy checks.
`contextMenuPresentationGeneration` invalidates pending contextual-menu presentation requests. Existing static
`CollectionSummaryService.matches` continues to compare supplied processing context and configuration values.

The separately approved service names are `MovieFolderFinderActionServicing` and `MovieFolderFinderActionService`.
Reveal remains an Unresolved Results action; Copy still requires an explicit Processing Details button press.
The existing native Copy/Reveal adapter remains a distinct boundary; the contextual-menu handler does not
perform clipboard writes or reveal selected results.

Compilation and reference checks were focused implementation checks. The later Implementation Phase approval
authorized its commit, and Validation Phase was explicitly authorized. Validation corrections require user review
before their commit; final integration still requires the feature-completion instruction.

Implementation check results for the naming correction: Debug host app and Finder extension compilation succeeded
with `CODE_SIGNING_ALLOWED=NO`; log: `/private/tmp/R110-04-naming-build.log`. The first sandboxed attempt could not
write the existing SwiftPM/Xcode caches; compilation succeeded when cache access was allowed. Source reference
searches found no remaining superseded request, menu controller/platform, or Finder inspection routing names.
Independent naming/selector/target-membership review found no semantic issues; naming-expanded long lines were
wrapped. `git diff --check` passed. These checks do not establish clipboard, Finder, accessibility, or runtime
qualification. No tests or SwiftLint were run during the naming correction itself. The later approved implementation
commit is `e2cf2eb`; formal validation follows below.

## Validation Phase — 2026-10-27

The user approved the implementation and explicitly requested validation. The implementation commit is
`e2cf2eb614347d3cb146529291ed4f8280eb697a` on `feature/finder-result-utilities`. Validation corrections below remain
uncommitted pending user approval; no merge or push is authorized.

| Required activity | Result | Evidence |
| --- | --- | --- |
| Verification | PASS for reviewed behavior and automated integration; no blocking findings | Independent review of request/menu naming, inspection, Copy/Reveal admission, retained access, cancellation and sheet routing |
| Unit testing | PASS: 80 tests in 6 host/Finder suites plus 2 Common request tests; no failures or skips | `/private/tmp/R110-04-validation-host-final.log`, `/private/tmp/R110-04-validation-common-final.log` |
| SwiftLint | Initial run: 0 errors, 9 warnings; follow-up after fixes: 0 warnings and 0 errors | SwiftLint 0.65.1, repository `.swiftlint.yml`; final report `/private/tmp/R110-04-all-warnings-final.json` |
| Swift style guide | PASS after required corrections; independent re-review found no unresolved issue-added deviations | Installed `swift-style-guide` skill and its reference; current corrections preserve behavior |

The six application suites were `FinderIntegrationTests`, `MovieFolderFinderActionServiceTests`,
`CollectionResultsViewModelTests`, `CollectionUnresolvedResultsTests`, `ConfigurationCoordinatorCoverageTests`,
and `MoviePosterActionServiceTests`. The Common suite was `MovieFolderContextMenuRequestTests`. Only these
issue-related suites ran; the application harness compiles other test sources as part of preparing the filtered
run. Compiler warnings concern pre-existing weak-variable mutability and unused results/values in test code,
including unchanged lines in Finder integration tests. The final Common run emitted no compiler warnings.

Validation corrected issue-added long lines, sorted imports, required guard/final-return blank-line spacing, and
missing public request/test/helper documentation. No behavior, safety fence, concurrency contract, lint rule or
threshold changed. `git diff --check` passed.

### Initial lint findings and cleanup

The first scoped run had nine warnings. The user asked for all to be fixed. The warning list below records the
initial findings and their resolution; no warning remains in the final scoped run.

Lint used `--use-script-input-files --no-cache --reporter json` with the 21 changed Swift paths and the repository
configuration. A separate parent-commit run established pre-existing findings:
`/private/tmp/R110-04-validation-swiftlint-baseline.json`. Eight remaining warnings are pre-existing:

- `CollectionResultsViewController.loadView`: function length, 70 → 72 relevant lines.
- `ConfigurationCoordinator`: file length, 505 → 555 relevant lines; existing statement positioning.
- `FinderIntegrationTests`: file length, 619 → 640 relevant lines; existing 121-character line.
- `MoviePosterActionService`: actor length improved from 329 → 301 relevant lines; existing 131-character line.
- `FinderSync`: existing 134-character line.

The ninth warning is new: `MovieFolderContextMenuHandler.contextMenu` contains 52 relevant lines against the
50-line warning threshold. It performs one cohesive menu-construction operation. The repository configuration
explicitly treats complexity metrics as indicators and rejects splitting solely to meet thresholds; review
accepted this warning without adding a layer or weakening the rule.

### Unperformed native qualification

No extension was registered and no live provider request was made. Native Finder-to-host activation, actual
clipboard/Finder selection, rendered layout, Light/Dark appearance, keyboard and VoiceOver interaction remain
unobserved. Authorization/access lifetime is supported by code review and injected-effect tests, not by native
sandbox qualification. Automated results do not establish these native checks.

## SwiftLint warning cleanup — 2026-10-27

The user requested correction of all nine warnings from the issue-scoped SwiftLint run, including findings present
in files modified for R110-04. The fixes were made without disabling or changing lint rules:

- Split the unresolved-results view setup into table, filter, action, layout, and keyboard-navigation methods.
- Split contextual-menu request and child-command construction into focused handler methods.
- Moved processor composition into a same-file private extension to keep the poster-action actor cohesive and below
  its configured type-body warning threshold.
- Moved collection setup/edit delegate flows into `ConfigurationCoordinator+CollectionFlows.swift`, preserving
  file-scoped implementation access with `fileprivate` where the adjacent file needs it. The application source
  tree is Xcode synchronized, so the new file participates in the host target.
- Moved shared Finder integration test fixtures into `FinderIntegrationFixtures.swift`; the application test
  harness copies every Swift source in the Finder test directory.
- Wrapped remaining overlong statements and corrected statement/whitespace layout.

The follow-up SwiftLint run used the repository `.swiftlint.yml`, version 0.65.1, and file-scoped inputs for all
18 changed/new Swift files: **0 warnings and 0 errors**. The final focused host tests passed 80 tests in 6 suites;
the Common request suite passed 2 tests in 1 suite. The app and Finder extension Debug build succeeded. The final
independent behavior and Swift style review passed. Report: `/private/tmp/R110-04-all-warnings-final.json`.
`git diff --check` passed. No lint configuration or thresholds were changed.

All nine initial warnings are fixed. Final checks on this tree: 80 host tests across 6 suites and 2 Common request
tests passed, no failures or skips; app and Finder extension Debug build succeeded; SwiftLint completed with 0
findings across 18 changed/new Swift files; reviewer PASS; `git diff --check` passed. Compiler warnings were
limited to pre-existing weak-variable and unused-result diagnostics in test sources; the Common final run emitted
none. The validation corrections were committed as `23a419a` and fast-forwarded to `develop`. Native Finder activation,
clipboard/Finder effects, and rendered accessibility checks remain unobserved.

## Integration and publication

On 2026-10-27, `feature/finder-result-utilities` was fast-forwarded into `develop`. The integrated implementation
and validation commits are `e2cf2eb` and `23a419a`. The issue documentation was then updated on `develop`; native
Finder activation, clipboard interaction, and accessibility qualification remain outstanding.
