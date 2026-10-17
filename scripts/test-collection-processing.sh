#!/bin/bash
set -euo pipefail

collection_processing_repository=$(cd "$(dirname "$0")/.." && pwd)
collection_processing_harness=$(rtk proxy mktemp -d "${TMPDIR:-/tmp}/MovieFolderPosters-CollectionProcessing.XXXXXX")
trap 'rtk proxy rm -rf "$collection_processing_harness"' EXIT
rtk proxy mkdir -p "$collection_processing_harness/Sources/MovieFolderPosters/Collections" \
  "$collection_processing_harness/Sources/MovieFolderPosters/Configuration" \
  "$collection_processing_harness/Tests/MovieFolderPostersTests" "$collection_processing_harness/Tests/Probe"
for source in "$collection_processing_repository"/MovieFolderPosters/Shared/Processing/Collections/*.swift; do
  rtk proxy cp "$source" "$collection_processing_harness/Sources/MovieFolderPosters/Collections/"
done
for source in Configuration/DirectoryConfiguration Configuration/ConfigurationRepository; do
  rtk proxy cp "$collection_processing_repository/MovieFolderPosters/Shared/$source.swift" \
    "$collection_processing_harness/Sources/MovieFolderPosters/Configuration/"
done
rtk proxy cp "$collection_processing_repository/MovieFolderPosters/MovieFolderPostersTests/Shared/Processing/Collections/CollectionProcessingModelTests.swift" \
  "$collection_processing_harness/Tests/MovieFolderPostersTests/"
rtk proxy cp "$collection_processing_repository/MovieFolderPosters/MovieFolderPostersTests/Shared/Processing/Collections/CollectionProcessingStoreTests.swift" \
  "$collection_processing_harness/Tests/MovieFolderPostersTests/"
rtk proxy cp "$collection_processing_repository/scripts/test-support/CollectionProcessingProbe/main.swift" \
  "$collection_processing_harness/Tests/Probe/main.swift"
rtk proxy ln -s "$collection_processing_repository/Packages/FileSystem" "$collection_processing_harness/FileSystem"
rtk proxy ln -s "$collection_processing_repository/Packages/Persistence" "$collection_processing_harness/Persistence"
rtk proxy tee "$collection_processing_harness/Package.swift" >/dev/null <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(name: "CollectionProcessingVerification", platforms: [.macOS("26.5")],
  dependencies: [.package(path: "FileSystem"), .package(path: "Persistence")],
  targets: [
    .target(name: "MovieFolderPosters", dependencies: [
      .product(name: "FileSystem", package: "FileSystem"),
      .product(name: "Persistence", package: "Persistence")
    ]),
    .executableTarget(name: "CollectionProcessingProbe", dependencies: [
      "MovieFolderPosters", "Persistence"
    ], path: "Tests/Probe"),
    .testTarget(name: "MovieFolderPostersTests", dependencies: [
      "MovieFolderPosters", "FileSystem", "Persistence"
    ])
  ], swiftLanguageModes: [.v6])
SWIFT
test_options=(--disable-sandbox)
if [[ "${COLLECTION_PROCESSING_BENCHMARK:-0}" == "1" ]]; then
  test_options+=(--filter largeInventory32RecordCheckpointsReportEncodeAndEnvelopeCost)
fi
SWIFTPM_MODULECACHE_OVERRIDE="$collection_processing_harness/.module-cache" \
  rtk proxy swift build --package-path "$collection_processing_harness" \
  --scratch-path "$collection_processing_harness/.build" --cache-path "$collection_processing_harness/.cache" \
  --config-path "$collection_processing_harness/.config" --security-path "$collection_processing_harness/.security" \
  --product CollectionProcessingProbe --disable-sandbox
COLLECTION_PROCESSING_PROBE_PATH="$collection_processing_harness/.build/arm64-apple-macosx/debug/CollectionProcessingProbe" \
SWIFTPM_MODULECACHE_OVERRIDE="$collection_processing_harness/.module-cache" \
  rtk proxy swift test --package-path "$collection_processing_harness" \
  --scratch-path "$collection_processing_harness/.build" --cache-path "$collection_processing_harness/.cache" \
  --config-path "$collection_processing_harness/.config" --security-path "$collection_processing_harness/.security" \
  "${test_options[@]}"
