# Log

An in-process Swift 6 service for bounded, typed activity history on macOS 26.5 or later.
The `Log` product contains one module and depends only on the local `Persistence` package.

## Use

Add `.package(path: "../Log")` to a sibling package and `"Log"` to its target dependencies.
All storage APIs are asynchronous and throwing:

```swift
import Foundation
import Log

enum ExampleEvent: String, Codable, Sendable {
  case operationCompleted
}

func recordExample(in authorizedDirectory: URL) async throws {
  let history = try await ActivityLog<ExampleEvent>(
    directory: authorizedDirectory, namespace: "example-activity")
  let committed = try await history.append(event: .operationCompleted)
  let retained = try await history.entries()
  assert(retained.last?.id == committed.id)
  try await history.clear()
}
```

The caller chooses an authorized, dedicated directory and stable nonempty namespace. Cooperating processes
must use the same event schema and retention configuration. The package does not obtain sandbox access,
select an App Group, publish notifications, render messages, or own application event vocabulary.

## Storage contract

- Entries have a UUID, caller-supplied occurrence timestamp, typed event, and increasing committed sequence.
  Reads return oldest-to-newest **commit order**; timestamps can arrive out of order.
- The default is the newest 500 entries. `maximumEntries` accepts 1 through 500. Each encoded event is limited
  to 2 KiB; the Persistence record envelope is limited to 2 MiB.
- Append, read, and Clear use an exclusive cross-process lease. Contention retries are cancellation-aware and
  bounded to approximately one second. Appends accept `accessMode: .immediate` for one nonwaiting attempt,
  useful while holding another service access. Contention fails without changing bytes or sequence; existing
  callers retain `.boundedWait` behavior. Filesystem work runs outside the caller's actor.
- Clear removes this history's entries while preserving the last sequence and reusable lock file. It does not
  erase other persistence records. Unreadable, corrupt, oversized, or unsupported history fails explicitly,
  including on Clear, and remains unchanged.
- Generic operations propagate cancellation. Append checks cancellation before committing; cancellation
  arriving after the final check may race with the atomic commit.

Typed payloads do not make arbitrary caller-defined events private. The consumer owns schema stability and
must exclude secrets, user paths, raw errors, or other sensitive values as appropriate. This is activity
storage, not system diagnostic logging or a background service.

## Documentation and verification

The `Sources/Log/Log.docc` catalog documents the module and public symbols.

Build its symbol graph and archive with the bundled toolchain from the package directory:

```sh
mkdir -p .build/docc-emitted .build/docc-symbols
swift build --target Log -Xswiftc -emit-symbol-graph \
  -Xswiftc -emit-symbol-graph-dir -Xswiftc "$PWD/.build/docc-emitted"
cp .build/docc-emitted/Log*.symbols.json .build/docc-symbols/
xcrun docc convert Sources/Log/Log.docc \
  --additional-symbol-graph-dir .build/docc-symbols \
  --output-path .build/Log.doccarchive
```

The copy selects this module and its extension graphs rather than compiling dependency documentation.
No documentation plugin is required.

Run `swift test` from this directory. Unit and multi-process storage tests do not establish signed App Group
access, Finder activation, or runtime UI behavior.
