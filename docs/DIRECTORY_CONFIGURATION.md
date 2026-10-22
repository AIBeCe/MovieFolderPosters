# Directory configuration

Movie Folder Posters is an AppKit configuration utility. Browse movies in Finder.
The host and Finder Sync extension coordinate Network, FileSystem, and Persistence as local, in-process SPM services.
No background daemon, filesystem watcher, or periodic scan is installed.

## Set up

1. Build and sign both targets with the same development team and registered App Group.
2. Run the host application and enable Movie Folder Posters in macOS Finder extension settings.
3. Choose **Add Folder** and select a movie collection directory in the native folder picker.
4. In Settings → TMDb, enter a TMDb **API Read Access Token**, then choose **Test and Save Token**.
5. Open the configured collection in Finder. Only immediate child folders are candidates.

Settings links to the TMDb API settings page and explains the required token. **Test Saved Token** explicitly
checks provider access without changing credentials or refreshing collections. Its safe result distinguishes
rejected credentials, connectivity, provider failures, and shared backoff. **Cancel** requests cancellation and
keeps overlapping actions disabled until the request returns. Viewing Settings does not itself test a token.

The token input clears after submission. The window reports whether a credential is configured, never its value.
**Test and Replace Token…** confirms replacement, tests the candidate, then saves only if the captured credential
generation is still current. **Remove Token…** confirms deletion of that same captured generation. Without a token,
configured roots remain registered, but processing
makes no metadata requests or icon changes. Removing a configured folder unregisters it and cancels its active work;
existing poster icons remain on disk.

The identification-data preview parses an entered example folder name locally. Choose Movie also shows the exact
normalized title and optional year that its explicit search will send. Neither preview initiates a search.
See [Credential setup and replacement](CREDENTIAL_SETUP.md) for migration, recovery, and qualification limits.

**Refresh Status** checks access and renews the host-to-extension handoff. If access needs restoration, select the
entry and choose **Locate Folder** to authorize it again. Unavailable directories remain configured so unmounted
volumes can recover without losing their settings. Symlink roots and duplicate paths are rejected.

Finder Sync observation is a navigation trigger, not a general filesystem change notification. A newly added movie
may require closing all views of its collection and reopening it. Duplicate Finder windows need not cause another
begin-observation callback. Open/Save dialogs can run separate extension instances.

Main also provides **Check Installation…** with component, signing, enablement, dated activation, setup, and bounded
shared-storage checks. Collection rows distinguish access evidence and uncertainty. New overlapping roots are rejected;
legacy overlaps block processing. See [Installation readiness](INSTALLATION_READINESS.md) for recovery instructions,
stable-identity rename behavior, the complete access matrix, and unperformed native checks.

## Poster appearance

Choose Raw (no styling), Soft finish (default), or Matte frame in the configuration window. The selection is shared
with the Finder extension. Cached application-owned icons update when a configured collection is revisited; foreign
and suppressed icons remain intact. See [Poster appearance](POSTER_APPEARANCE.md) for rendering and verification.

## Signing and process permissions

Both bundles use registered App Group `group.dag.fikios.MovieFolderPosters`, provisioned for team `N74TV576H8` on the
development Mac. Production distribution must provision the group for its chosen team. Do not commit profiles or
signing credentials. Automatic signing can refresh profiles with `xcodebuild -allowProvisioningUpdates`.

Both targets are sandboxed and have user-selected read/write access, app-scoped bookmarks, and the shared App Group.
Both the host and Finder extension use outgoing network access. SPM modules do not independently acquire entitlements.
The temporary hardcoded TestMovies path exception has been removed.

An App Group shares configuration; it does not grant access to arbitrary movie directories. Each process keeps its
own persistent security-scoped bookmark in its private container. The host creates an ordinary transfer bookmark
from the picker grant; the extension resolves that handoff and creates its own persistent bookmark. A scoped lease
keeps authorization alive across awaited processing and ends it when ownership is released.

The implicit transfer grant can expire. If an extension has never established its own bookmark before that happens,
reopen the host and refresh or locate the folder. Persisted extension access was verified across process termination;
reboot behavior remains untested. Renewed grants have an authorization version so stale host snapshots cannot replace
new authorization.

Sandbox-safe descriptor traversal uses `O_SEARCH` for ancestors and opens the authorized final directory for reading.
Opening ancestors with `O_RDONLY` caused the reported startup failure: the sandbox denied reading `/Users` before
access reached the shared container. Descriptor anchoring and `O_NOFOLLOW` retain path replacement protections.

## Storage and credentials

Shared settings contain folder identifiers, paths, transfer bookmarks, authorization versions, and a credential
revision. Persistence provides versioned opaque records, atomic writes, and cross-process exclusive leases.
Configuration reads retry only lease contention: at most eight attempts with seven 20 ms waits, initiated by a load
or configuration event. There is no idle retry loop or periodic scanning.

The TMDb token is a generic password in the shared **Data Protection Keychain**, using the registered App Group as its
access group. It is never written to settings, tests, logs, or source. Revision updates commit under the settings lease
before the Keychain mutation; notifications invalidate cached clients even when a credential operation fails.
A failed Keychain operation can leave a newer revision without changing the credential, which is safe to retry.

Old authorization records and cached posters can remain after removing a root. They are inactive records; automatic
cache eviction and a user cleanup interface are outside this phase.

## App architecture and lifecycle

The view controller renders controls, the view model serializes user actions and presents state, and the coordinator
owns the single configuration window. The host service coordinates authorization, persistence, and credential changes.
The Finder layer registers roots and forwards events to an actor scheduler. Reloads cancel and await previous work
before replacing authorization or processor state. Observations arriving during reload are retained and filtered
against the new roots; closing and reopening during cancellation queues a replacement without concurrent processing.
While Finder observes a configured root, the scheduler watches that root directory for filesystem changes and
coalesces a burst into one additional visit. The event is advisory: the processor inventories immediate children and
revalidates authorization, root identity, and mutation policy before writing. It does not recursively observe movie
folders. A provider backoff result schedules one retry at its recorded deadline while that root remains observed.
Ending observation, changing configuration, or stopping the extension cancels its event source and deferred retry.
Extension termination does not preserve a timer; a later Finder observation can resume eligible work from durable
state. Unsupported or unavailable filesystem notifications may delay detection until another Finder visit.

The existing processor preserves unrelated custom icons, caches metadata and posters, and bounds work. Version-2
settings retain a separate processing-cache revision across credential changes, preserving usable saved movie
decisions. Version-1 settings anchor this namespace to their existing credential revision. Operational caches carry
the captured credential generation; a changed generation discards cached queries and authentication-specific
failures while retaining decisions, manual-required classifications, and provider throttling. Fixture-mode changes
rotate both generations to separate fixture decisions from live work. Older builds reject version-2 settings.
Native custom icons persist independently of host or extension lifetime. Movie files and names are unchanged.

## Development and verification

The Codex Run action calls `./script/build_and_run.sh`. It builds a signed Debug app, registers the embedded extension,
and launches the host. Modes include `--debug`, `--logs`, `--telemetry`, and `--verify`; verification checks process
liveness, not full UI readiness. `MOVIE_POSTERS_DERIVED_DATA` selects an alternate build directory.

Debug accepts explicit `--development-fixtures` and `--disable-development-fixtures` app arguments for deterministic
metadata transport. Fixtures still require a configured credential and authorized root. Release always uses live TMDb,
regardless of the fixture flag. Use only invalid fixture credentials in development probes.

Run focused checks with `scripts/test-configuration.sh`, `scripts/test-configuration-ui.sh`, and the local package tests.
See [Phase 6 verification](PHASE_6_VERIFICATION.md) for executed results and unperformed checks.

## Platform references

- [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [Implicit bookmark security scopes](https://developer.apple.com/documentation/foundation/nsurl/bookmarkcreationoptions/withoutimplicitsecurityscope)
- [Apple DTS: transferring bookmark authorization between processes](https://developer.apple.com/forums/thread/785735)
- [Accessing App Group containers](https://developer.apple.com/documentation/xcode/accessing-app-group-containers)
- [Sharing Keychain access](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)
- [Data Protection Keychain](https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain)
- [Finder Sync lifecycle](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html)
