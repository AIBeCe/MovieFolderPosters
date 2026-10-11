# Phase 5 verification

Date: 2026-10-11. Environment: Apple Silicon, macOS 26.5, Xcode 26.6, Swift 6.
Branch: `feature/automatic-posters`, created from `develop`.

## Native Finder result

The signed AppKit host and embedded Finder Sync extension were built and registered locally. Old development
registrations were removed so Finder selected the Phase 5 build. Finder was restarted for extension reload.

The configured root was the isolated `TestMovies/Phase5Integration` fixture, containing two releases of the
fictional movie The Last Frame and one unknown title. Opening the root produced a real Finder observation callback.
Controlled HTTP responses passed through TMDbClient, ReleaseNameParser, MovieMatcher, MovieFolderProcessor,
Persistence, and FileSystem before native custom-icon assignment.

Observed first processing at 22:45:27–22:45:28 local time:

- Three candidates examined; two posters assigned; one unresolved; zero processing failures.
- One search, one configuration lookup, and one poster download served both releases of the same movie.
- A separate search for the unknown movie produced an unresolved record.
- Finder rendered the poster in place of the folder icon at both large and normal icon sizes.

The extension was then disabled and terminated, and Finder restarted. Both posters still rendered. FinderInfo
custom-icon flags remained set for the matching folders; the unknown folder retained its default icon.
Fixture content hashes were unchanged. Native icon files and resource forks are expected custom-icon metadata.

After restoring the extension, a new process observed the same root at 22:46:57:

- Zero candidates processed; zero icons assigned; both existing icons preserved.
- The unresolved folder remained in its retry window.
- No development transport calls occurred during that observation.
- Icon resource-fork hashes and modification times were unchanged.
- Begin callback to processing completion was approximately two milliseconds for this small repeat fixture.

A final rebuilt Debug process repeated the same cache-only result at 22:55:37 after the review fixes:
zero candidates processed, zero assignments, two existing icons preserved, and no transport calls.

This validates event-triggered processing and icon persistence with deterministic metadata responses. It does
not validate a live TMDb account, remote service latency, or arbitrary collection permissions.

## Automated and build verification

All implementation reviews passed after fixing path-confinement, partial-failure, cancellation,
stale-record retention, and image-validation findings. No blocking review finding remains.

The corrected scale fixture uses real temporary directories and Persistence records, controlled metadata,
and a fake icon writer. FinderInfo flags represent completed icon assignment after each processing run.
This measures scan/cache behavior; it does not measure 498 native icon writes or live network latency.

- Initial processing of 498 candidates: approximately 3.748 seconds with controlled provider responses.
- 498 existing icons plus two new candidates: approximately 42 milliseconds; exactly two assignments.
- Repeat visit to 500 existing icons: approximately 19 milliseconds; zero assignments.
- Search count and fake assignment count remain 500 after the repeat visit; poster download count remains one.

The earlier missing-icon fixture exercised cache restoration and took seconds on subsequent visits; it was
not accepted as an unchanged-collection performance result. Separate restoration tests cover that behavior.

| Check | Result |
| --- | --- |
| Network service | 21 test functions passed, including parameterized cases |
| Release-name parser | 7 test functions passed, including parameterized cases |
| Conservative matcher | 19 test functions passed, including parameterized cases |
| FileSystem service | 24 tests passed; independent review PASS |
| Persistence service | 8 tests passed; independent review PASS |
| Application processing | 19 tests passed; independent review PASS |
| Final signed Debug build-for-testing | Passed, including actual host and test target |
| Signed Release build | Passed; development transport compiled out |
| Debug/Release bundle signatures | Deep and strict verification passed |
| Swift source length | At most 120 characters per line |
| Native icon persistence | Passed with extension disabled and Finder restarted |
| Native repeat visit | Passed: zero requests, zero icon writes |

The application tests are run from their actual source files in temporary SwiftPM harnesses. This avoids the
previously observed AppKit-hosted test-run finalization stall. Xcode build-for-testing separately compiles the
actual test target and verifies integration. Successful compilation is not reported as successful execution.

## Remaining boundaries

- Debug Finder integration uses explicitly identified HTTP fixtures. Release builds do not use them.
- No real TMDb token is present in source, Git, or this verification session. Secure credential configuration
  and live provider verification remain outstanding.
- The temporary directory entitlement is development-only. User-selected arbitrary directory authorization
  remains Phase 6 work, including the previously discovered bookmark-sharing limitations.
- Finder observation callbacks are not general filesystem notifications and need not run for duplicate windows.
- NSWorkspace custom icons persist without the extension; path-based assignment still has the documented
  external-rename race inherent in that API.
- No Phase 6 implementation, daemon, watcher, polling, merge, or push was performed.

## Integration history

Approved components from the separate Phase 2–4 feature branches were brought into this Phase 5 working tree
as source dependencies. Those branches and `develop` were not merged or modified. Their integration history
remains a separate GitFlow decision.
