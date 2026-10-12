#!/bin/bash
set -euo pipefail

# Compile production processing, parsing, and matching sources with real local services.
processing_repository=$(cd "$(dirname "$0")/.." && pwd)
processing_harness=$(rtk proxy mktemp -d "${TMPDIR:-/tmp}/MovieFolderPosters-Processing.XXXXXX")
trap 'rtk proxy rm -rf "$processing_harness"' EXIT
rtk proxy mkdir -p "$processing_harness/Sources/MovieFolderPosters" \
    "$processing_harness/Tests/MovieFolderPostersTests"
rtk proxy cp "$processing_repository/MovieFolderPosters/MovieFolderPosters/ReleaseNameParser.swift" \
    "$processing_harness/Sources/MovieFolderPosters/ReleaseNameParser.swift"
rtk proxy cp "$processing_repository/MovieFolderPosters/MovieFolderPosters/MovieMatcher.swift" \
    "$processing_harness/Sources/MovieFolderPosters/MovieMatcher.swift"
rtk proxy cp "$processing_repository/MovieFolderPosters/MovieFolderPosters/MovieFolderProcessor.swift" \
    "$processing_harness/Sources/MovieFolderPosters/MovieFolderProcessor.swift"
rtk proxy cp "$processing_repository/MovieFolderPosters/MovieFolderPostersTests/MovieFolderProcessorTests.swift" \
    "$processing_harness/Tests/MovieFolderPostersTests/MovieFolderProcessorTests.swift"
rtk proxy ln -s "$processing_repository/Packages/FileSystem" "$processing_harness/FileSystem"
rtk proxy ln -s "$processing_repository/Packages/Network" "$processing_harness/Network"
rtk proxy ln -s "$processing_repository/Packages/Persistence" "$processing_harness/Persistence"
rtk proxy tee "$processing_harness/Package.swift" >/dev/null <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(name: "ProcessingVerification", platforms: [.macOS("26.5")],
                      dependencies: [
    .package(path: "FileSystem"), .package(path: "Network"), .package(path: "Persistence")
], targets: [
    .target(name: "MovieFolderPosters", dependencies: [
        .product(name: "FileSystem", package: "FileSystem"),
        .product(name: "Network", package: "Network"),
        .product(name: "Persistence", package: "Persistence")
    ]),
    .testTarget(name: "MovieFolderPostersTests", dependencies: [
        "MovieFolderPosters", "FileSystem", "Network", "Persistence"
    ])
], swiftLanguageModes: [.v6])
SWIFT
if [[ -n "${PROCESSING_TEST_FILTER:-}" ]]; then
    rtk proxy swift test --package-path "$processing_harness" --filter "$PROCESSING_TEST_FILTER"
else
    rtk proxy swift test --package-path "$processing_harness"
fi
