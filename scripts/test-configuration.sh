#!/bin/bash
set -euo pipefail
configuration_repository=$(cd "$(dirname "$0")/.." && pwd)
configuration_harness=$(rtk proxy mktemp -d "${TMPDIR:-/tmp}/MovieFolderPosters-Configuration.XXXXXX")
trap 'rtk proxy rm -rf "$configuration_harness"' EXIT
rtk proxy mkdir -p "$configuration_harness/Sources/MovieFolderPosters" \
    "$configuration_harness/Tests/MovieFolderPostersTests"
for source in Configuration/DirectoryConfiguration Configuration/ConfigurationRepository FinderIntegration/DirectoryObservationScheduler Configuration/SharedEnvironment Security/KeychainCredentialStore; do
    rtk proxy cp "$configuration_repository/MovieFolderPosters/Shared/$source.swift" \
        "$configuration_harness/Sources/MovieFolderPosters/"
done
rtk proxy cp "$configuration_repository/MovieFolderPosters/MovieFolderPostersTests/Shared/Configuration/DirectoryConfigurationTests.swift" \
    "$configuration_harness/Tests/MovieFolderPostersTests/"
rtk proxy cp "$configuration_repository/MovieFolderPosters/MovieFolderPostersTests/Shared/FinderIntegration/DirectoryObservationSchedulerTests.swift" \
    "$configuration_harness/Tests/MovieFolderPostersTests/"
rtk proxy cp "$configuration_repository/MovieFolderPosters/MovieFolderPosters/Features/Collections/DirectoryConfigurationService.swift" \
    "$configuration_harness/Sources/MovieFolderPosters/"
rtk proxy cp "$configuration_repository/MovieFolderPosters/MovieFolderPostersTests/Features/Collections/DirectoryConfigurationServiceTests.swift" \
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
SWIFTPM_MODULECACHE_OVERRIDE="$configuration_harness/.module-cache" \
    rtk proxy swift test --disable-sandbox ${CONFIGURATION_TEST_FLAGS:-} \
    --package-path "$configuration_harness" --scratch-path "$configuration_harness/.build" \
    --cache-path "$configuration_harness/.cache" --config-path "$configuration_harness/.config" \
    --security-path "$configuration_harness/.security"
