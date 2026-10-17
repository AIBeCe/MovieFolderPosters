#!/bin/bash
set -euo pipefail

# Compile production processing, parsing, and matching sources with real local services.
processing_repository=$(cd "$(dirname "$0")/.." && pwd)
processing_harness=$(rtk proxy mktemp -d "${TMPDIR:-/tmp}/MovieFolderPosters-Processing.XXXXXX")
trap 'rtk proxy rm -rf "$processing_harness"' EXIT
rtk proxy mkdir -p "$processing_harness/Sources/MovieFolderPosters" \
    "$processing_harness/Tests/MovieFolderPostersTests"
rtk proxy cp "$processing_repository/MovieFolderPosters/Shared/Processing/ReleaseNameParser.swift" \
    "$processing_harness/Sources/MovieFolderPosters/ReleaseNameParser.swift"
rtk proxy cp "$processing_repository/MovieFolderPosters/Shared/Processing/MovieMatcher.swift" \
    "$processing_harness/Sources/MovieFolderPosters/MovieMatcher.swift"
rtk proxy cp "$processing_repository/MovieFolderPosters/Shared/Processing/MovieFolderProcessor.swift" \
    "$processing_harness/Sources/MovieFolderPosters/MovieFolderProcessor.swift"
for source in Configuration/DirectoryConfiguration Configuration/ConfigurationRepository; do
    rtk proxy cp "$processing_repository/MovieFolderPosters/Shared/$source.swift" \
        "$processing_harness/Sources/MovieFolderPosters/"
done
rtk proxy cp "$processing_repository/MovieFolderPosters/MovieFolderPostersTests/Shared/Processing/MovieFolderProcessorTests.swift" \
    "$processing_harness/Tests/MovieFolderPostersTests/MovieFolderProcessorTests.swift"
rtk proxy cp "$processing_repository/MovieFolderPosters/MovieFolderPostersTests/Shared/Processing/MoviePosterActionTests.swift" \
    "$processing_harness/Tests/MovieFolderPostersTests/MoviePosterActionTests.swift"
rtk proxy cp "$processing_repository/MovieFolderPosters/MovieFolderPostersTests/Resources/TestPoster.png" \
    "$processing_harness/Tests/MovieFolderPostersTests/TestPoster.png"
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
    ], resources: [.copy("TestPoster.png")])
], swiftLanguageModes: [.v6])
SWIFT
processing_test_options=(--disable-sandbox)
if [[ -n "${PROCESSING_TEST_FILTER:-}" ]]; then
    processing_test_options+=(--filter "$PROCESSING_TEST_FILTER")
fi
SWIFTPM_MODULECACHE_OVERRIDE="$processing_harness/.module-cache" \
    rtk proxy swift test --package-path "$processing_harness" \
    --scratch-path "$processing_harness/.build" --cache-path "$processing_harness/.cache" \
    --config-path "$processing_harness/.config" --security-path "$processing_harness/.security" \
    "${processing_test_options[@]}"
