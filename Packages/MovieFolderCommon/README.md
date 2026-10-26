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
Importing this package grants no filesystem or Keychain authorization. Do not hold `PersistenceAccess` across
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
`usesStubTMDbResponses`, `MovieFolderActivityLogEvent.Status`, and `status` are the current Swift API names.

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
  let didRecordWithoutFailure = await recorder.record(
    MovieFolderActivityLogEvent(action: .applicationOpened, status: .succeeded))
  if didRecordWithoutFailure {
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

`MovieFolderActivityLogEvent` combines closed action/status/result vocabulary with historical display facts from
`MovieFolderActivityLogContext`. Capture context from a configured directory or its trusted status before
asynchronous work, then use `context.event(...)` with the actual child result and confirmed movie facts.
`MovieFolderActivityLogTarget` contains collection name, immediate child folder name, and optional confirmed
movie ID/title/year. It never accepts a full child path or arbitrary rendered message. All presentation surfaces
consume the same full `event.text`. Legacy collection events explicitly state that details were not recorded.
`failureEvidence(for:stage:occurredAt:)` classifies known typed errors without retaining raw descriptions.
Actual `ProcessingSummary` counters keep unresolved, applied, restyled, deferred, and unchanged work distinct.
Retry dates describe eligibility and never promise that a retry has been scheduled.

The recorder lazily opens `movie-activity` with at most 500 retained entries, 8 KiB encoded events, and a 1 MiB
serialized payload budget before the Persistence envelope's base64 expansion. Oldest entries are trimmed on
count or byte limits. Complete oversized details fall back to explicit fixed omission evidence; names are never
silently shortened by the recorder. Activity reads legacy version 1 and writes version 2, which older writers
reject without changing stored bytes. Network keeps its separate version-one 2 KiB event default.

Unlinked writes retain cancellation-aware bounded contention. Collection-linked writes open history first,
then retain shared settings through an immediate append. Generic `Log` APIs propagate cancellation, while
`record(_:)` independently awaits its bounded append so a cancelled producer can record terminal evidence.
It returns `false` for an actual history write failure and preserves the product result. The async property
`hasObservedWriteFailure` tracks process-local write failures separately from throwing read/Clear failures.
Corrupt or unsupported history remains explicit and is not silently replaced, including on Clear.

## Private activity and optional network history

Configuration schema 5 stores `MonitoredDirectory.usesPrivateHistory`, `isNetworkHistoryRecordingEnabled` (default off),
and `networkHistoryConfigurationRevision`. Explicit CodingKeys preserve the on-disk `isPrivate`,
`retainsNetworkHistory`, and `historyRevision` fields unchanged. Normal readers/writers use only schema 5.
The explicit `MovieFolderStorageMigrator` upgrades settings versions 1–4 and collection processing schema 1 to 2,
with verified original-payload backups in a dedicated namespace. Missing historical privacy/history fields receive
established defaults; explicit choices and generations are preserved. Normal reads return a typed upgrade-required
error rather than migrating or resetting records. See [saved-data schema migration](../../docs/STORAGE_SCHEMA_MIGRATION.md).
Changing history recording, collection privacy, root membership, or root identity/authorization rotates only
history revision. Processing, cache, and authorization generations are unaffected by privacy choices.

Production `MovieFolderEnvironment.makeActivityRecorder()` always injects shared configuration. Each new
collection-linked write checks current settings; private or removed roots drop both collection/group UUIDs.
Both capture-time and current privacy remove target fields and collection/group UUIDs. Names-bearing events
without a collection ID are redacted even in explicitly configured test recorders. Unreadable settings
intentionally omit linked optional activity. `record(_:)` returns true for intentional
omission, sends no change notification, and does not report a storage failure. Explicit test construction may
omit configuration for legacy controlled scenarios; production composition must retain enforcement.

Successful removal uses `ConfigurationRepository.removeCollection(_:)` and its immutable, non-Codable
`CommittedCollectionRemoval` receipt. Only `recordCollectionRemoval(_:)` may preserve a public removed name;
it rechecks current settings and any reused identifier. Generic missing-root events remain unlinked, and a
private capture or a reintroduced private collection prevents retention. Existing retained history is unchanged.

`MovieFolderEnvironment.makeNetworkHistoryService()` is nonthrowing. It supplies a bounded independent
`movie-network` history or an explicit unavailable fallback. A `MovieFolderNetworkRequestRecorder` binds a
provider client to an optional collection UUID. Before dispatch it obtains the current history revision, then
holds no access during networking. On terminal completion it rechecks enabled recording, revision, and an
existing nonprivate collection before an immediate append under configuration access. Disabled recording,
private or removed collections, stale tickets, and unreadable settings intentionally omit history. Fixture
transport composition omits the recorder; real credential diagnostics remain observable in movie fixture mode.
Actual storage/append contention failures are tracked separately and never replace a provider result.

Network events contain only closed request purpose, HTTP/transport outcome, terminal timestamp, and an optional
nonprivate collection UUID. They contain no query, title, year, URL, header, body, credential, path, bookmark, or
arbitrary error. HTTP 2xx evidence does not claim successful movie matching or poster decoding. Each history
retains at most 500 entries. Network uses 2 KiB events; Activity uses 8 KiB events and a 1 MiB payload budget.
Both retain the 2 MiB outer Persistence record limit. Disabling recording and making a collection
private retain old entries unchanged until explicit source-specific Clear. Omitted history is never reconstructed.
Payload-free change hints are published after shared accesses are released. Updated host/Finder binaries are
required for these checks; older running binaries cannot inherit them.

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
