# Phase 7 verification

Branch: `feature/finder-actions`, created from develop with approved Phase 6 source dependencies carried forward.
Phase 6 was committed as `e542d41`. No merge or push is included.

## Automated checks

| Check | Result |
| --- | --- |
| FileSystem package | 35 tests passed |
| Processing and manual actions | 32 tests passed, including 19 existing regression tests and 13 action tests |
| Configuration and scheduling | 17 tests passed |
| Action view model | 5 Swift Testing cases passed via `scripts/test-poster-action-ui.sh` |
| Custom URL requests | 5 cases passed, including all four action round trips and rejected routes |
| Signed Debug app | Build and normal launch passed |
| Signed Release app and extension | Final build and strict deep signature verification passed |
| Xcode test compilation | Final Debug build-for-testing passed; tests were not launched |
| Independent review | PASS, including authorization fencing, cross-revision coordination, and stale menu requests |
| Swift style | Source lines meet the 120-character limit |

Focused tests used controlled metadata responses and actual temporary directories. No production movie files were changed.
Host URL scheme and outgoing-network permissions were checked in the built bundle and signed DER entitlements.
XML entitlement display produced a tool warning; DER extraction and strict signature verification succeeded.

## Platform evidence

The isolated native FileSystem probe confirmed successful custom-icon assignment, hidden regular `Icon\r` storage,
and a ResourceFork that changed with a later icon replacement. Ownership checks therefore compare actual icon bytes,
not just a marker or Finder flag. Package tests cover owned assignment, user replacement preservation, explicit removal,
suppression, re-assignment, external clearing, target identity, and symlink safety.

## Native Finder and host checks

The current signed Debug extension displayed all four direct **Movie Poster:** commands on the isolated child folder
`The.Last.Frame.2026.1080p.Phase7` under the authorized temporary collection.

- Refresh opened the host confirmation for the captured folder. Its explicit button completed with
  “Poster refreshed from TMDb movie 1.”
- Remove opened its own confirmation and completed with “Poster removed.” The folder suppression xattr was `1`.
- Change opened with the parsed title/year, searched only after a click, and displayed the fixture title/year/TMDb ID.
  Apply remained disabled until an explicit selection. Applying restored the poster and reported the assigned ID.
- The selected movie detail button reported opening the fixed TMDb URL. Exact URL construction was unit tested;
  external browser page rendering could not be independently inspected through the enabled browser surface.

The fixture movie bytes remained unchanged. Fixture mode was disabled after verification, and the existing configured
root and Keychain credential were preserved. The normal host remained available through these actions.

The Finder bridge strips `representedObject` (observed payload=false) but preserves scalar menu tags. Captured requests
now use unique tags per menu generation; stale callbacks expire instead of retargeting another folder. The host validates
captured identity and current authorization rather than depending on a second selection lookup after menu closure.
Only the direct commands were accepted as the final tested UI; nested submenu behavior was not established.

Duplicate temporary app registrations initially caused Finder to run the Release copy instead of the intended Debug
extension. The live executable was inspected, temporary copies were unregistered, and the intended copy was retested.

## Reported crashes

Three crash reports from 20:15/20:17 on 2026-10-12 contained XCTest injection and a Swift concurrency abort in
`XCTSwiftErrorObservation`. The new XCTest helper kept an idle callback installed and fulfilled an expectation more
than once. That helper was corrected; the new action tests were then converted to Swift Testing with one-shot waits
and a reproducible isolated SwiftPM harness. Further GUI test retries were stopped. Normal signed launch and native
manual actions passed, and no newer MovieFolderPosters crash report appeared during the final checks.

## Review decisions

Independent review found that asynchronous notification cancellation alone could not fence a late manual write after
configuration changed during a download. Manual writes now require a synchronous current-configuration lease.
It also found credential revisions created separate processing locks; an independent stable root coordination store
now serializes automatic and manual work across those revisions.

## Limits

Live TMDb credentials, reboot, and physical unmounted-volume behavior remain unverified. Native UI and Finder checks
use an isolated test folder and explicitly enabled Debug metadata fixtures. Legacy unmarked posters remain preserved.
First-page-only search is explicit in the UI; pagination and poster preview are outside this phase. A selected candidate
can be inspected on TMDb before applying it. Other applications do not share the app's icon mutation locks.
