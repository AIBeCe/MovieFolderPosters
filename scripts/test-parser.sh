#!/bin/bash
set -euo pipefail

# Compile copies of the production parser and its actual Xcode tests without launching the AppKit host.
parser_repository=$(cd "$(dirname "$0")/.." && pwd)
parser_harness=$(rtk proxy mktemp -d "${TMPDIR:-/tmp}/MovieFolderPosters-Parser.XXXXXX")
trap 'rtk proxy rm -rf "$parser_harness"' EXIT
rtk proxy mkdir -p "$parser_harness/Sources/MovieFolderPosters" "$parser_harness/Tests/MovieFolderPostersTests"
rtk proxy cp "$parser_repository/MovieFolderPosters/Shared/Processing/ReleaseNameParser.swift" \
    "$parser_harness/Sources/MovieFolderPosters/ReleaseNameParser.swift"
rtk proxy cp "$parser_repository/MovieFolderPosters/MovieFolderPostersTests/Shared/Processing/ReleaseNameParserTests.swift" \
    "$parser_harness/Tests/MovieFolderPostersTests/ReleaseNameParserTests.swift"
rtk proxy tee "$parser_harness/Package.swift" >/dev/null <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(name: "ParserVerification", platforms: [.macOS("26.5")], targets: [
    .target(name: "MovieFolderPosters"),
    .testTarget(name: "MovieFolderPostersTests", dependencies: ["MovieFolderPosters"])
], swiftLanguageModes: [.v6])
SWIFT
rtk proxy swift test --package-path "$parser_harness"
