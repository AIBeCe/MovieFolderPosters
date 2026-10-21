# MovieFolderCommon

The shared in-process implementation consumed by the Movie Folder Posters AppKit host and Finder extension.
The `MovieFolderCommon` product contains one module, organized by Activity, Configuration, Processing,
Development (Debug only), FinderIntegration, and Security. It depends on the local `Network`, `FileSystem`,
`Persistence`, `Log`, and `MovieFolderParsing`
packages. It requires Swift tools 6.2, Swift 6 language mode, and macOS 26.5 or later.

## Composition and ownership

Add `.package(path: "../MovieFolderCommon")` to a sibling package and `"MovieFolderCommon"` to its target
dependencies, or add the local package product to an Xcode target. Both signed executables import the same
module rather than compiling copies of its sources.

The package consumes `MovieFolderParsing` for release-name parsing and owns matching, processing decisions,
collection processing state, shared configuration models,
Finder request/scheduling logic, typed activity, a Keychain adapter, environment setup, and a Debug TMDb stub transport.
It does not create a separate process.
The host owns AppKit windows, presentation, and navigation; Finder Sync remains the integration boundary.
`MovieFolderProcessorConfiguration.standard` preserves the existing retry and search-cache timings. A caller
may pass a validated immutable configuration to a processor initializer. Each folder still persists its own
retry deadline; the configuration is captured per processor instance, which may serve multiple collections.
`MovieFolderEnvironment` resolves App Group directories, opens repositories, and publishes change notifications in
the calling process. Signed executables retain their App Group/Keychain entitlements and explicit Debug stub
selection. `StubTMDbTransport` is available only when compiling with `DEBUG`; callers supply poster bytes.
The Boolean setting `usesStubTMDbResponses` explicitly selects these responses in Debug.
Importing this package grants no filesystem or Keychain authorization. Do not hold mutation leases across
networking or other unbounded work.

Activity history, collection processing state, configuration, caches, and icon ownership remain separate stores.
Clearing activity never authorizes a poster operation or erases collection processing state.

## Existing processing storage

Current storage uses `CollectionProcessingState`. An existing legacy directory requires the explicit
[offline migration](../../docs/PROCESSING_STATE_STORAGE_MIGRATION.md) after older app/extension processes are
stopped. Normal factory calls do not migrate it implicitly or open an empty replacement store.
The migration preserves original record bytes, keys, and lock identities; a legacy-path marker blocks older
stores from recreating a separate namespace. Do not delete that marker.

Source naming changes retain the existing JSON keys `developmentFixtures` and `outcome` through CodingKeys.
`usesStubTMDbResponses`, `MovieFolderActivityEvent.Status`, and `status` are the current Swift API names.

## Typed activity

```swift
import Foundation
import MovieFolderCommon

struct ExampleActivityNotifier: MovieFolderActivityChangeNotifying {
  func movieFolderActivityDidChange() {
    // Publish a payload-free invalidation hint through the composition layer's transport.
  }
}

func recordExample(in authorizedActivityDirectory: URL) async throws {
  let recorder = MovieFolderActivityRecorder(
    directory: authorizedActivityDirectory, notifier: ExampleActivityNotifier())
  let didCommit = await recorder.record(
    MovieFolderActivityEvent(action: .applicationOpened, status: .succeeded))
  if didCommit {
    let history = try await recorder.entries()
    assert(history.last?.event.action == .applicationOpened)
  }
  try await recorder.clear()
}
```

The recorder strongly retains the required Sendable notifier. A successful append or Clear calls it after
commit. Notifications contain no event payload and are only invalidation hints: readers reload committed
storage, including on opening/reopening or activation to recover missed notifications. The example notifier
is intentionally a no-op; a real signed application supplies the transport.

`MovieFolderActivityEvent` accepts only fixed actions/statuses and optional opaque UUIDs. Fixed text and
categories are rendered locally; serialized events contain no tokens, bookmarks, user paths, movie/folder
names, remote URLs, or raw underlying error descriptions. Producers must report actual operation evidence.

The recorder lazily opens the `movie-activity` namespace with 500-entry retention, 2 KiB events and a 2 MiB
Persistence envelope. Entries are returned in committed sequence, independently of occurrence timestamps;
Clear preserves the latest sequence. Lease contention is cancellation-aware and bounded to approximately
one second. Generic `Log` APIs propagate cancellation, while `record(_:)` independently awaits a bounded
best-effort append so a cancelled producer can still record its terminal event. It returns `false` on write
failure and preserves the product operation's result. The async property `hasObservedWriteFailure` retains process-local write-failure
evidence separately from throwing read/Clear failures. Corrupt or unsupported history remains an explicit
error, including on Clear, and is not silently replaced.

## Documentation and verification

The `Sources/MovieFolderCommon/MovieFolderCommon.docc` catalog provides the public module guide.

Build its symbol graph and archive with the bundled toolchain from the package directory:

```sh
mkdir -p .build/docc-emitted .build/docc-symbols
swift build --target MovieFolderCommon -Xswiftc -emit-symbol-graph \
  -Xswiftc -emit-symbol-graph-dir -Xswiftc "$PWD/.build/docc-emitted"
cp .build/docc-emitted/MovieFolderCommon*.symbols.json .build/docc-symbols/
xcrun docc convert Sources/MovieFolderCommon/MovieFolderCommon.docc \
  --additional-symbol-graph-dir .build/docc-symbols \
  --output-path .build/MovieFolderCommon.doccarchive
```

The copy selects this module and its extension graphs rather than compiling dependency documentation.
No documentation plugin is required.

Run `swift test` from this directory. The separate collection probe and host feature harnesses under the
repository's `scripts/` cover composition outside this package. Package tests do not establish signed
Finder-process exchange, live provider calls, icon persistence, UI accessibility, reboot, or physical-volume
qualification. See [the migration record](../../docs/COMMON_AND_LOG_MIGRATION.md) for current evidence and limits.
