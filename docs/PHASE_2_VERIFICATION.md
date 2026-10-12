# Phase 2 — Local Finder Poster Proof

Opening the configured TestMovies directory in Finder installs the bundled poster as the native custom icon
of its immediate child ObservationChild. This is a development spike with one local image and one explicit target.

## Scope

- Swift 6, AppKit host, Finder Sync extension, and local FileSystem package.
- No third-party dependencies, network requests, parsing, cache, background service, watcher, or polling.
- Finder Sync callbacks launch retained, cancellable work on a dedicated processing actor.
- FileSystem rejects hidden/nested target names, files, symbolic links, and missing directories.
- Existing custom icons are preserved, including icons installed outside this application.
- ImageIO decodes and orients the local image, then scales it proportionally onto a transparent 512-square canvas.
- NSWorkspace.setIcon writes the native custom icon; a process-wide mutex serializes those calls.

## Development sandbox access

The extension remains sandboxed. Its temporary absolute-path read/write exception is limited to:

```text
/Users/davidalarcon/Development/Projects/MovieFolderPosters/TestMovies/
```

The trailing slash is required for a directory exception. This is a machine-specific development entitlement,
not the final configurable-directory permission strategy or a promise of Mac App Store acceptance.
On another Mac, update both Phase2Configuration.swift and the extension entitlement to the same isolated test path.

The attempted document-scoped directory bookmark was rejected at runtime. Apple documents that document-scoped
bookmarks target individual files, not directories. FileSystem's remaining bookmark API uses app scope and must
not be treated as a mechanism for sharing authorization between the host and extension.

[Apple sandbox exception reference](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html)

[Apple document-scoped bookmark limitation](https://developer.apple.com/library/archive/technotes/tn2312/_index.html)

[Apple cross-process bookmark guidance](https://developer.apple.com/forums/thread/785735)

## Reproduce

From the repository root, with Xcode signing configured for the development team:

```sh
rtk proxy mkdir -p TestMovies/ObservationChild
rtk proxy swift test --package-path Packages/FileSystem --scratch-path /tmp/MovieFolderPosters-FileSystem-build
rtk proxy xcodebuild -project MovieFolderPosters/MovieFolderPosters.xcodeproj \
    -scheme MovieFolderPosters -configuration Debug -derivedDataPath /tmp/MovieFolderPosters-Phase2 build
rtk proxy open /tmp/MovieFolderPosters-Phase2/Build/Products/Debug/MovieFolderPosters.app
rtk proxy pluginkit -a /tmp/MovieFolderPosters-Phase2/Build/Products/Debug/MovieFolderPosters.app/Contents/PlugIns/MovieFolderPostersFinder.appex
rtk proxy pluginkit -e use -i dag.fikios.MovieFolderPosters.Finder
rtk proxy open TestMovies
```

Enable the extension in System Settings if required. If another directory window already observes TestMovies,
close those test windows and reopen it: beginObservingDirectory does not run for every duplicate window.
Finder Sync is not a general filesystem notification API; adding a folder does not guarantee a new callback.

The configured test child must have no custom icon for first assignment. A pre-existing icon is intentionally
preserved. Use a fresh isolated fixture to repeat the initial assignment test; do not strip real movie icons.

Inspect diagnostic events with:

```sh
rtk proxy log show --last 10m --style compact --predicate 'subsystem == "dag.fikios.MovieFolderPosters"'
```

An initial observation logs “Assigned bundled poster to the explicit test child”. Later visits log
“Preserved existing custom icon; no write needed”. User directory paths remain private in logs.

## Observed results on 2026-10-11

| Check | Result |
| --- | --- |
| Package behavioral tests | 15 passed; nine new poster tests first failed against the stub |
| Signed Debug build, Xcode build-for-testing, and deep signature validation | Passed |
| Swift line length | New and changed Swift sources at most 120 characters |
| Independent semantic review | Passed |
| Actual Finder callback and icon assignment | Passed; extension pid 34777 assigned the bundled image |
| Finder icon sizes and list view | Poster visibly rendered in both tested sizes and list view |
| Persistence with extension disabled and terminated | Passed |
| Persistence across Finder restart | Passed; extension stayed disabled during observation |
| Repeat visit after re-enabling extension | Preserved existing icon without rewriting |
| Content fixture | SHA-256 unchanged from before icon assignment |
| Folder name | ObservationChild unchanged |

macOS created a hidden file named Icon followed by a carriage return (Icon\r), whose resource fork held
287,810 bytes of icon data, and set the containing folder's FinderInfo custom-icon flag (0x0400).
The existing content fixture retained its bytes; movie files were not renamed or modified.
The icon appeared without an explicit Finder refresh command.

## Remaining limitations

- Arbitrary user-selected directory authorization across host/extension lifetimes still needs a supported design.
- App Groups share their own container; they do not confer access to an external movie directory.
- The temporary directory entitlement must be replaced before a configurable release.
- Process-local task and icon-write synchronization does not provide cross-process transactions. Multiple
  extension instances may observe the same root; this spike uses the same image and preserves installed icons.
- Validation and native icon writes cannot form a filesystem transaction against concurrent external renames.
- Large collections, external filesystems, and network volumes have not been tested.
- Finder remained responsive during this one-folder proof; no collection-scale performance claim is made.

The fixed-directory extension-only icon workflow is demonstrated. Continue with Phase 3 only after approval.
