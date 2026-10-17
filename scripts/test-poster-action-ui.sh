#!/bin/bash
set -euo pipefail

# Compile the real poster action view model and its behavior tests without Xcode's test host.
poster_repository=$(cd "$(dirname "$0")/.." && pwd)
poster_harness=$(rtk proxy mktemp -d "${TMPDIR:-/tmp}/MovieFolderPosters-Action.XXXXXX")
trap 'rtk proxy rm -rf "$poster_harness"' EXIT
rtk proxy mkdir -p "$poster_harness/Sources/MovieFolderPosters" \
    "$poster_harness/Tests/MovieFolderPostersTests"
rtk proxy cp "$poster_repository/MovieFolderPosters/MovieFolderPosters/Features/PosterActions/MoviePosterActionViewModel.swift" \
    "$poster_harness/Sources/MovieFolderPosters/"
rtk proxy cp "$poster_repository/MovieFolderPosters/Shared/FinderIntegration/MoviePosterRequest.swift" \
    "$poster_harness/Sources/MovieFolderPosters/"
rtk proxy cp "$poster_repository/MovieFolderPosters/Shared/Processing/ReleaseNameParser.swift" \
    "$poster_harness/Sources/MovieFolderPosters/"
rtk proxy cp "$poster_repository/MovieFolderPosters/MovieFolderPostersTests/Features/PosterActions/MoviePosterActionViewModelTests.swift" \
    "$poster_harness/Tests/MovieFolderPostersTests/"
rtk proxy cp -R "$poster_repository/Packages/Network" "$poster_harness/Network"
rtk proxy python3 - "$poster_repository" "$poster_harness/Sources/MovieFolderPosters/ServiceContract.swift" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
target = Path(sys.argv[2])
service = (root / "MovieFolderPosters/MovieFolderPosters/Features/PosterActions/MoviePosterActionService.swift").read_text()
start = service.index("nonisolated protocol MoviePosterActionServicing: Sendable {")
end = service.index("\n}\n", start) + 2
contract = service[start:end]
target.write_text("import Foundation\nimport Network\n\n" + contract + "\n")
PY
rtk proxy tee "$poster_harness/Sources/MovieFolderPosters/ActionHarnessSupport.swift" >/dev/null <<'SWIFT'
import Foundation

nonisolated enum PosterActionError: Error, Equatable {
    case busy
    case unresolved
    case foreignIcon
    case changedIdentity
    case noPoster
}

nonisolated enum ConfigurationError: Error {
    case busy
}

nonisolated enum MoviePosterActionServiceError: Error, LocalizedError, Sendable {
    case directoryNotConfigured
    case directoryUnavailable
    case configurationChanged
    case childChanged
    case credentialUnavailable
    case invalidSelection
    case invalidQuery

    var errorDescription: String? { "Action service error" }
}
SWIFT
rtk proxy tee "$poster_harness/Package.swift" >/dev/null <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PosterActionVerification",
    platforms: [.macOS("26.5")],
    dependencies: [.package(path: "Network")],
    targets: [
        .target(name: "MovieFolderPosters", dependencies: [.product(name: "Network", package: "Network")]),
        .testTarget(name: "MovieFolderPostersTests", dependencies: ["MovieFolderPosters"])
    ],
    swiftLanguageModes: [.v6]
)
SWIFT
SWIFTPM_MODULECACHE_OVERRIDE="$poster_harness/.module-cache" \
    rtk proxy swift test --disable-sandbox --package-path "$poster_harness" \
    --scratch-path "$poster_harness/.build" --cache-path "$poster_harness/.cache" \
    --config-path "$poster_harness/.config" --security-path "$poster_harness/.security"
