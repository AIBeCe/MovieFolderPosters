#!/bin/bash
set -euo pipefail

# Run the actual application matcher and fixtures without launching the AppKit test host.
matching_repository=$(cd "$(dirname "$0")/.." && pwd)
matching_harness=$(rtk proxy mktemp -d "${TMPDIR:-/tmp}/MovieFolderPosters-Matching.XXXXXX")
trap 'rtk proxy rm -rf "$matching_harness"' EXIT
rtk proxy mkdir -p "$matching_harness/Sources/MovieFolderPosters" "$matching_harness/Tests/MovieFolderPostersTests"
rtk proxy cp "$matching_repository/MovieFolderPosters/MovieFolderPosters/MovieMatcher.swift" \
    "$matching_harness/Sources/MovieFolderPosters/MovieMatcher.swift"
rtk proxy cp "$matching_repository/MovieFolderPosters/MovieFolderPostersTests/MovieMatcherTests.swift" \
    "$matching_harness/Tests/MovieFolderPostersTests/MovieMatcherTests.swift"
# A symlink avoids interpolating repository paths into Swift source.
rtk proxy ln -s "$matching_repository/Packages/Network" "$matching_harness/Network"
rtk proxy tee "$matching_harness/Package.swift" >/dev/null <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(name: "MatchingVerification", platforms: [.macOS("26.5")],
                      dependencies: [.package(path: "Network")], targets: [
    .target(name: "MovieFolderPosters", dependencies: [.product(name: "Network", package: "Network")]),
    .testTarget(name: "MovieFolderPostersTests", dependencies: ["MovieFolderPosters", "Network"])
], swiftLanguageModes: [.v6])
SWIFT
rtk proxy swift test --package-path "$matching_harness"
