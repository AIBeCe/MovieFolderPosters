#!/bin/bash
set -euo pipefail

# Compile the real configuration view model and its behavior tests without the Xcode host.
configuration_repository=$(cd "$(dirname "$0")/.." && pwd)
configuration_harness=$(rtk proxy mktemp -d "${TMPDIR:-/tmp}/MovieFolderPosters-Configuration.XXXXXX")
trap 'rtk proxy rm -rf "$configuration_harness"' EXIT
rtk proxy mkdir -p "$configuration_harness/Sources/MovieFolderPosters" \
    "$configuration_harness/Tests/MovieFolderPostersTests"
rtk proxy cp "$configuration_repository/MovieFolderPosters/Shared/DirectoryConfiguration.swift" \
    "$configuration_harness/Sources/MovieFolderPosters/DirectoryConfiguration.swift"
rtk proxy cp -R "$configuration_repository/Packages/FileSystem" "$configuration_harness/FileSystem"
if [[ -f "$configuration_repository/MovieFolderPosters/MovieFolderPosters/ConfigurationViewModel.swift" ]]; then
    rtk proxy cp "$configuration_repository/MovieFolderPosters/MovieFolderPosters/ConfigurationViewModel.swift" \
        "$configuration_harness/Sources/MovieFolderPosters/ConfigurationViewModel.swift"
fi
rtk proxy cp "$configuration_repository/MovieFolderPosters/MovieFolderPosters/ConfigurationViewController.swift" \
    "$configuration_harness/Sources/MovieFolderPosters/ConfigurationViewController.swift"
rtk proxy cp "$configuration_repository/MovieFolderPosters/MovieFolderPosters/ConfigurationCoordinator.swift" \
    "$configuration_harness/Sources/MovieFolderPosters/ConfigurationCoordinator.swift"
for source in SettingsViewController AppAppearanceSettings LogViewController PreviewChoiceButton; do
    if [[ -f "$configuration_repository/MovieFolderPosters/MovieFolderPosters/$source.swift" ]]; then
        rtk proxy cp "$configuration_repository/MovieFolderPosters/MovieFolderPosters/$source.swift" \
            "$configuration_harness/Sources/MovieFolderPosters/$source.swift"
    fi
done
rtk proxy mkdir -p "$configuration_harness/Sources/MovieFolderPosters/Resources"
rtk proxy cp "$configuration_repository/MovieFolderPosters/MovieFolderPosters/PreviewPoster.png" \
    "$configuration_harness/Sources/MovieFolderPosters/Resources/PreviewPoster.png"
rtk proxy cp \
    "$configuration_repository/MovieFolderPosters/MovieFolderPostersTests/ConfigurationViewModelTests.swift" \
    "$configuration_harness/Tests/MovieFolderPostersTests/ConfigurationViewModelTests.swift"
rtk proxy tee "$configuration_harness/Package.swift" >/dev/null <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ConfigurationVerification",
    platforms: [.macOS("26.5")],
    dependencies: [.package(path: "FileSystem")],
    targets: [
        .target(name: "MovieFolderPosters", dependencies: [.product(name: "FileSystem", package: "FileSystem")],
                resources: [.process("Resources")]),
        .testTarget(name: "MovieFolderPostersTests", dependencies: [
            "MovieFolderPosters", .product(name: "FileSystem", package: "FileSystem")
        ])
    ],
    swiftLanguageModes: [.v6]
)
SWIFT
SWIFTPM_MODULECACHE_OVERRIDE="$configuration_harness/.module-cache" \
    rtk proxy swift test --disable-sandbox --package-path "$configuration_harness" \
    --scratch-path "$configuration_harness/.build" --cache-path "$configuration_harness/.cache" \
    --config-path "$configuration_harness/.config" --security-path "$configuration_harness/.security"
