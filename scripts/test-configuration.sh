#!/bin/bash
set -euo pipefail
configuration_repository=$(cd "$(dirname "$0")/.." && pwd)
configuration_harness=$(rtk proxy mktemp -d "${TMPDIR:-/tmp}/MovieFolderPosters-Configuration.XXXXXX")
trap 'rtk proxy rm -rf "$configuration_harness"' EXIT
rtk proxy mkdir -p "$configuration_harness/Sources/MovieFolderPosters" \
    "$configuration_harness/Tests/MovieFolderPostersTests"
for source in DirectoryConfiguration ConfigurationRepository DirectoryObservationScheduler SharedEnvironment KeychainCredentialStore; do
    rtk proxy cp "$configuration_repository/MovieFolderPosters/Shared/$source.swift" \
        "$configuration_harness/Sources/MovieFolderPosters/"
done
rtk proxy cp "$configuration_repository/MovieFolderPosters/MovieFolderPostersTests/DirectoryConfigurationTests.swift" \
    "$configuration_harness/Tests/MovieFolderPostersTests/"
rtk proxy cp "$configuration_repository/MovieFolderPosters/MovieFolderPostersTests/DirectoryObservationSchedulerTests.swift" \
    "$configuration_harness/Tests/MovieFolderPostersTests/"
rtk proxy cp "$configuration_repository/MovieFolderPosters/MovieFolderPosters/DirectoryConfigurationService.swift" \
    "$configuration_harness/Sources/MovieFolderPosters/"
rtk proxy cp "$configuration_repository/MovieFolderPosters/MovieFolderPostersTests/DirectoryConfigurationServiceTests.swift" \
    "$configuration_harness/Tests/MovieFolderPostersTests/"
rtk proxy ln -s "$configuration_repository/Packages/FileSystem" "$configuration_harness/FileSystem"
rtk proxy ln -s "$configuration_repository/Packages/Persistence" "$configuration_harness/Persistence"
rtk proxy tee "$configuration_harness/Package.swift" >/dev/null <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "ConfigurationVerification", platforms: [.macOS("26.5")],
                      dependencies: [.package(path: "Persistence"), .package(path: "FileSystem")], targets: [
    .target(name: "MovieFolderPosters", dependencies: [.product(name: "Persistence", package: "Persistence"),
        .product(name: "FileSystem", package: "FileSystem")]),
    .testTarget(name: "MovieFolderPostersTests", dependencies: ["MovieFolderPosters", "Persistence"])
], swiftLanguageModes: [.v6])
SWIFT
rtk proxy swift test ${CONFIGURATION_TEST_FLAGS:-} --package-path "$configuration_harness"
