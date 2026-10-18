# Host coordinator architecture

Date: 2026-10-18
Status: Implemented, verified, and independently reviewed; user approved commit on 2026-10-18.
Integration remains pending the explicit instruction to finish the feature.

## Approved scope

Refactor the host's flow ownership without changing movie processing, stored formats, configured roots,
poster actions, or Finder permissions. Continue on `feature/processing-recovery`; do not commit, merge,
push, close issues, or implement later recovery-policy points as part of this work.

```text
AppDelegate
└── AppCoordinator
    ├── ConfigurationCoordinator
    │   ├── Main collection/configuration window
    │   ├── Settings window and existing tabs
    │   └── Folder picker, installation report, processing details sheets
    ├── LogCoordinator
    │   └── Log window and activity presentation
    └── MoviePosterActionCoordinator
        └── Finder-requested poster actions
```

The root owns application-wide routing, shared service composition, activation/reopen handling, and app
appearance. AppDelegate forwards OS events and menu requests. Configuration requests Log presentation
through a focused weak delegate; only the root connects sibling flows. Log initialization and presentation
must not require configuration, collection-processing storage, or summary-service initialization to succeed.
Each feature owns its window creation, reuse, and flow state. Settings tabs do not need child coordinators.

Product activity is recorded through the retained activity service. ActivityLogViewModel presents history
and handles Log-specific actions; other workflows must not depend on it to record events. App-wide appearance
must cover poster-action windows as well as Main, Settings, Log, and inherited sheets.

Collection-record cleanup follows committed root removal in the configuration workflow, independently of
view creation or successful subsequent summary loading. Cleanup failure must not misreport a committed
removal as failed; record its failure separately, preserving startup/later-invocation cleanup recovery.
Keep the existing cross-process configuration fencing and namespace boundaries.

Local write results, including failed writes without a successful-append notification, route from
configuration through its weak coordinator delegate to the root and then LogCoordinator. Root-owned
activity writes likewise invalidate Log through the root. Recording remains service-owned, and opening
Log is never required for recording. Log's presentation retains failed-write evidence across later reloads.

Notification registrations have explicit ownership and teardown. Preserve poster-action cancellation on
close/replacement and protection against late asynchronous results. Report construction and AppKit layout
belong in focused models/controllers rather than a coordinator's UI-building method.

## Implementation and verification plan

1. Add behavioral tests for independent Log routing, feature window reuse/reopen, poster-action request
   replacement/close cancellation, application appearance, and observer teardown where testable.
2. Introduce AppCoordinator/LogCoordinator and narrow ConfigurationCoordinator; forward AppDelegate events,
   route sibling requests through delegates, and move report rendering to a focused view controller.
3. Move cleanup into the configuration mutation workflow and test removal without UI, summary-read failure,
   and cleanup failure independently of successful removal. Retain operational recording services directly.
4. Update host harness source/test discovery for the new application tests if required. Run focused host
   tests, complete host/Common regressions, and signed Debug/Release build verification. Do not launch the
   live application or mutate user collections merely to validate this refactor.
5. Run SwiftLint once at final validation using `.swiftlint.yml`; compare findings against the unchanged
   HEAD to distinguish new violations from existing ones without changing rules or unrelated code.
6. Complete independent review with the same implementation/review owners through any corrections.
   Record final evidence and remaining native limits here. Stop before committing for user approval.

## Progress and evidence

- [x] Coordinator hierarchy and routing implemented.
- [x] Operational activity and committed-removal cleanup ownership corrected.
- [x] Window, appearance, cancellation, and observer lifecycle regression coverage.
- [x] Focused/full automated verification and signed builds.
- [x] Final SwiftLint comparison and independent review.
- [x] User approved commit on 2026-10-18; no integration until explicitly instructed to finish the feature.

## Implementation decisions and verification

ConfigurationCoordinator now lives under Features/Collections. LogCoordinator owns its window, view model,
and notification subscription. AppDelegate retains AppCoordinator and forwards lifecycle, menu, and validated
Finder URL events. The Window menu exposes Log independently of successful configuration initialization.
The existing startup error remains configuration-specific; dismissing it leaves independent routes usable.

DirectoryConfigurationService retains the processing-store cleaner and activity service. Production
composition always supplies the real processing store. After committing removal, cleanup runs before a
later summary read; cleanup errors record a separate failure without undoing or failing committed removal.
Existing startup cleanup remains a retry path. No root-removal cleanup depends on view-model observation.

An isolated AppKit probe and the new lifecycle test showed that setting NSApplication.appearance alone
does not update existing windows' effective appearance. AppCoordinator therefore applies the preference
to NSApplication and its windows, including retained closed windows; later windows inherit application
appearance. System restores nil overrides. No feature maintains a competing appearance policy.

InstallationReadinessViewController owns report layout. ConfigurationCoordinator retains presentation
decisions, folder-picking, and sheet presentation. Selector-based invalidations register only when the
corresponding flow starts and unregister on owner destruction. Poster-action request replacement and
window closing still cancel actual service tasks and fence late results.

| Verification | Evidence |
| --- | --- |
| Removal regressions | Observed failing before service cleanup; pass after fix, including failed later summary read and failed cleanup |
| Host feature/lifecycle harness | 81 Swift Testing tests in 6 suites passed; includes real AppKit windows with isolated services |
| Common regression | 44 XCTest tests and 102 Swift Testing tests in 12 suites passed |
| Local failed-write regression | Failed with stale open Log, then passed after root-routed result invalidation |
| Independent review | PASS after resolving I1, the failed-write invalidation regression |
| Signed Debug/Release builds | Final-tree Debug build-for-testing and Release build succeeded |
| Strict signature verification | Both app bundles passed deep/strict checks outside the restricted sandbox; valid on disk and designated requirements satisfied |
| SwiftLint 0.65.1 | 159 findings, 6 serious versus committed baseline 164/6; no new findings after relocation/line-movement comparison |

Host harness discovery includes Application tests as well as Features and executes serially because AppKit
window/appearance integration uses process-global application state. Tests cover Log after failed configuration
construction, Main/Settings/Log reuse, appearance before and after changes including sheets/poster windows,
actual search cancellation on replacement/close, and released presentation owners. They do not establish
manual signed-host window behavior, live Finder actions, or a new production qualification.

Final logs are `/private/tmp/coordinator-host-final.log` and
`/private/tmp/mfp-coordinator-validation-{common,debug-final2,release-final2,codesign-debug,codesign-release}.log`.
Lint reports use `/private/tmp/mfp-coordinator-validation-lint-{head,final2}.json`.
Restricted signature inspection initially could not access the signing authority; the same strict verification
passed with read-only execution outside that sandbox. No signing identity, Keychain trust, lint rule, or build
threshold was changed. Existing lint findings were retained rather than triggering unrelated refactoring.

The user approved committing the refactor on `feature/processing-recovery`. No merge, push, issue closure,
live-provider processing, live collection mutation, or additional recovery-policy implementation was performed.

Native Finder callbacks, live provider traffic, physical-volume behavior, VoiceOver speech, and manual
window interaction are not established by source review, unit tests, or successful builds.
