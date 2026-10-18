#!/bin/bash
set -euo pipefail
source "$(rtk proxy dirname "$BASH_SOURCE")/common-tests.sh"
host_harness=$(rtk proxy mktemp -d "${TMPDIR:-/tmp}/MovieFolderPosters-HostFeatures.XXXXXX")
trap 'rtk proxy rm -rf "$host_harness"' EXIT
rtk proxy mkdir -p "$host_harness/Sources/MovieFolderPosters" "$host_harness/Tests/MovieFolderPostersTests"
# Native host code remains a separate consumer of Common, matching the Xcode module boundary.
for directory in Application Features UI Resources; do
  rtk proxy cp -R "$common_repository/MovieFolderPosters/MovieFolderPosters/$directory" \
    "$host_harness/Sources/MovieFolderPosters/"
done
rtk proxy rm "$host_harness/Sources/MovieFolderPosters/Application/AppDelegate.swift"
rtk proxy cp -R "$common_repository/MovieFolderPosters/MovieFolderPostersTests/Features" \
  "$host_harness/Tests/MovieFolderPostersTests/"
if [[ -d "$common_repository/MovieFolderPosters/MovieFolderPostersTests/Application" ]]; then
  rtk proxy cp -R "$common_repository/MovieFolderPosters/MovieFolderPostersTests/Application" \
    "$host_harness/Tests/MovieFolderPostersTests/"
fi
for package in MovieFolderCommon Network FileSystem Persistence Log; do
  rtk proxy ln -s "$common_repository/Packages/$package" "$host_harness/$package"
done
rtk proxy tee "$host_harness/Package.swift" >/dev/null <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
  name: "HostFeatureVerification",
  platforms: [.macOS("26.5")],
  dependencies: [
    .package(path: "MovieFolderCommon"), .package(path: "Network"), .package(path: "FileSystem"),
    .package(path: "Persistence"), .package(path: "Log")
  ],
  targets: [
    .target(name: "MovieFolderPosters",
            dependencies: ["MovieFolderCommon", "Network", "FileSystem", "Persistence", "Log"],
            exclude: ["Resources/Assets.xcassets", "Resources/Base.lproj"],
            resources: [.process("Resources/PreviewPoster.png")],
            swiftSettings: [
              .defaultIsolation(MainActor.self),
              .enableUpcomingFeature("InferIsolatedConformances"),
              .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]),
    .testTarget(name: "MovieFolderPostersTests",
                dependencies: ["MovieFolderPosters", "MovieFolderCommon", "Network", "FileSystem", "Persistence", "Log"],
                swiftSettings: [.enableUpcomingFeature("NonisolatedNonsendingByDefault")])
  ],
  swiftLanguageModes: [.v6])
SWIFT
SWIFTPM_MODULECACHE_OVERRIDE="$common_cache/module-cache" \
CLANG_MODULE_CACHE_PATH="$common_cache/clang-cache" \
  rtk proxy swift test --package-path "$host_harness" --disable-sandbox \
    --cache-path "$common_cache/cache" --config-path "$common_cache/config" \
    --security-path "$common_cache/security" --no-parallel --filter "${1:-MovieFolderPostersTests}"
