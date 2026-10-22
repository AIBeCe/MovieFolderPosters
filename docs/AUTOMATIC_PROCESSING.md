# Automatic movie folder processing

Phase 5 connects the approved parser and conservative matcher to three in-process local SPM services.
The Finder extension compiles the same application processing source as the host. No daemon, watcher, polling,
or third-party package is introduced.

## Service ownership

- Network owns HTTP requests, TMDb response validation, and poster downloads.
- FileSystem owns immediate-child discovery, folder identities, poster image files, and native custom icons.
- Persistence owns opaque versioned records, atomic writes, and nonblocking cross-process leases.
- Application source owns release names, matching policy, retry decisions, and processing order.

Persistence uses per-key SHA-256 filenames and versioned JSON envelopes. A lease holds an advisory `flock`
until its owner releases it or its process exits. Descriptor-relative operations protect storage against path
replacement and symlink ancestors. Invalid records surface errors rather than being silently accepted.

Only visible immediate child directories are candidates. Existing custom icons are preserved, including icons
installed by the user or another application. Movie contents are never opened, indexed, renamed, or edited.
Native icon assignment creates Apple's custom-icon metadata; see PHASE_2_VERIFICATION.md for filesystem effects.

Processing is serial and runs outside Finder callbacks. Cross-process root leases prevent concurrent observers
from performing the same work. Callbacks cancel retained work when observation ends. Finder Sync observation is
not a filesystem change notification, and opening another window for an already-observed directory may not
produce another begin callback. A newly added folder can therefore wait until observation begins again.

Query results and unresolved outcomes eligible for automatic reassessment expire after 24 hours. Confirmed
Not found and Several matches outcomes remain in manual resolution regardless of retry-date expiry. Transient
folder errors wait ten minutes; authentication failures defer the root for 24 hours. Rate limits use
Retry-After with a one-minute to 24-hour bound. Removed folder records and expired queries are pruned during
observation. Poster files remain cached; no periodic eviction is introduced. Cache validation uses bounded
thumbnails. A missing icon can be restored from its cached poster while failures remain isolated to that folder.
When a saved movie decision has missing or invalid source artwork, R100-08 repairs it from the saved provider
path on a later processing visit. The repair is limited to one download attempt per poster path per visit,
validates bytes before replacing cache data, preserves the saved match on failure, and does not rewrite an
already-owned folder icon when only its source cache needs repair. See [Cached artwork repair](CACHED_ARTWORK_REPAIR.md).

## Development integration

The configured test root is `TestMovies/Phase5Integration` under this repository. Development permission remains
a narrow temporary sandbox exception covering `TestMovies/`. Arbitrary user-selected directories and persistent
shared authorization remain Phase 6 work.

Debug builds use controlled TMDb HTTP responses through the real TMDbClient. Only the exact test title
`The Last Frame` resolves; other titles remain unresolved. The bundled original test poster is the image fixture.
No live TMDb request or real credential is involved. Release builds disable this fixture and explicitly log that
secure credential configuration is pending. This is a development integration milestone, not a configured
production metadata service.

## Verification

Service unit suites and application processing tests exercise persistence, filtering, cache reuse, cancellation,
retry policy, and concurrent observers. The Xcode build verifies target membership, strict Swift 6 concurrency,
signing, embedding, and extension resources. Native Finder checks and measured collection results are recorded
in PHASE_5_VERIFICATION.md after execution.

## Platform limits

NSWorkspace accepts a filesystem path for icon assignment. Identity is checked immediately before mutation,
but macOS does not offer descriptor-relative custom-icon assignment; an external rename at that exact instant
cannot be made atomic with this API. Finder rendering may require a fresh observation or refresh. Existing icons
remain independent of the extension and its cache after assignment.

To create the explicit development folders in a fresh checkout:

```sh
rtk proxy mkdir -p \
  TestMovies/Phase5Integration/The.Last.Frame.2026.1080p.WEB-DL-FIRST \
  TestMovies/Phase5Integration/The.Last.Frame.2026.2160p.BluRay-SECOND \
  TestMovies/Phase5Integration/Unknown.Movie.2026.1080p.WEB-DL-GROUP
```

Build the Debug host, register/enable its embedded extension, and open that root in Finder. Directory registration
and enabling do not grant filesystem permission; this fixture works only under the documented development
entitlement. Use the verified local commands in PHASE_2_VERIFICATION.md with `Phase5` as the DerivedData directory.
