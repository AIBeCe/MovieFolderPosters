#!/bin/bash
set -euo pipefail
request_repository=$(cd "$(dirname "$0")/.." && pwd)
request_harness=$(rtk proxy mktemp -d "${TMPDIR:-/tmp}/MovieFolderPosters-Requests.XXXXXX")
trap 'rtk proxy rm -rf "$request_harness"' EXIT
rtk proxy mkdir -p "$request_harness/Sources/MovieFolderPosters" "$request_harness/Tests/MovieFolderPostersTests"
rtk proxy cp "$request_repository/MovieFolderPosters/Shared/MoviePosterRequest.swift" \
    "$request_harness/Sources/MovieFolderPosters/"
rtk proxy cp "$request_repository/MovieFolderPosters/MovieFolderPostersTests/MoviePosterRequestTests.swift" \
    "$request_harness/Tests/MovieFolderPostersTests/"
rtk proxy tee "$request_harness/Package.swift" >/dev/null <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "RequestVerification", platforms: [.macOS("26.5")], targets: [
    .target(name: "MovieFolderPosters"),
    .testTarget(name: "MovieFolderPostersTests", dependencies: ["MovieFolderPosters"])
], swiftLanguageModes: [.v6])
SWIFT
rtk proxy swift test --package-path "$request_harness"
