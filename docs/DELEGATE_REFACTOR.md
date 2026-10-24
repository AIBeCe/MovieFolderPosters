# Protocol-based communication

Publication update — 2026-10-18: the completed work was included in the push of `develop` through `b48d44d`.
Earlier no-push statements below describe the verification date. Native qualification limits remain unchanged.

The user approved refactoring existing callbacks to delegates on 2026-10-17.
Keep feature folders, MVVM-C, Swift 6 isolation, and existing behavior.

The subsequently approved [host coordinator refactor](COORDINATOR_ARCHITECTURE.md) adds AppCoordinator as
the application root. Configuration and Log are independent child flows; sibling presentation requests and
local activity-write results route through the root. Collection-removal cleanup no longer uses a view delegate.
The original verification records below remain historical evidence for the delegate migration.

## Decisions

- UI event delegates are class-bound, main-actor isolated, and weakly referenced. Coordinators own flow lifetime.
- Configuration presentation supports multiple weak delegate subscribers so Main and Settings remain synchronized.
- Required service collaborators and processing-policy checkers are protocol-based and strongly retained; missing weak
  delegates must never bypass an authorization or configuration check.
- Scheduler callbacks remain actor-safe and preserve cancellation, serialization, and reload ordering.
- Local algorithms, structured Task bodies, transactions, and framework-required completion handlers retain closures.
  This refactor replaces object communication, rather than syntax required by Swift and Apple APIs.

## Implementation and verification

- [x] Replace host navigation, row actions, presentation/activity, appearance, and Log callbacks.
- [x] Replace poster-action presentation/navigation callbacks.
- [x] Replace injected installation/configuration collaborators with narrow protocols.
- [x] Replace scheduler and processing-check callbacks with protocol delegates while preserving `PersistenceAccess`
  lifetime.
- [x] Verify delegate lifetime, multiple subscribers, cancellation, and existing processing/access regressions.
- [x] Run signed Debug/Release builds and independent review; record results and remaining native limitations.

No movie contents, runtime policy, or custom-icon behavior is intentionally changed. Existing native qualification
limits in [Installation readiness](INSTALLATION_READINESS.md) remain in effect.

### Focused verification

- Configuration and scheduler: 32 Swift Testing tests passed.
- Configuration AppKit interface: 24 Swift Testing tests passed.
- Installation readiness: 17 Swift Testing tests passed.
- Poster-action interface: 8 Swift Testing tests passed.
- Processing and manual actions: 43 XCTest tests passed.
- Added checks for weak delegate lifetimes, multicast subscription changes, navigation sender/URLs, required
  collaborator retention, saved-state notification ordering, cancellation, and leases held during icon assignment.
- Standalone harnesses compile without the host target's default main-actor isolation. Signed Xcode builds additionally
  verify those settings; readiness protocol requirements and native evidence helpers declare nonisolated execution.

### Final verification

- Signed Debug `build-for-testing` passed for the host, embedded Finder extension, unit tests, and UI tests.
- Signed Release build passed. Strict deep signature verification passed for both app bundles.
- Independent review: PASS, no open Critical or Important findings.
- `git diff --check` passed; changed Swift files satisfy the 120-character line limit.
- Build diagnostics include expected App Intents metadata extraction notices and Debug test-only weak-variable
  suggestions. No build errors remain.
- Native Finder activation/reconnection/reboot, sandbox handoff, and filesystem compatibility qualification were not
  repeated. This refactor does not close the existing installation-readiness qualification work.
- The delegate refactor was committed as `5beabc6`. The complete readiness feature was subsequently integrated into
  local `develop` at `55ba0a6` on 2026-10-17; issue #1 is closed and its feature branch was deleted. No push was performed.
- Later native checks are recorded in [Native qualification](NATIVE_READINESS_QUALIFICATION.md); they are separate
  evidence from the delegate refactor's original verification.
