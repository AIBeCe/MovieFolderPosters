#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(rtk dirname "$0")/.." && rtk pwd)"
temp_root="$(rtk mktemp -d /tmp/mfp-installation-readiness.XXXXXX)"
trap 'rtk rm -rf "$temp_root"' EXIT

rtk mkdir -p "$temp_root/Sources/MovieFolderPosters" "$temp_root/Tests/MovieFolderPostersTests"
rtk cp "$repo_root/MovieFolderPosters/MovieFolderPosters/Features/Installation/InstallationReadiness.swift" \
  "$temp_root/Sources/MovieFolderPosters/"
rtk proxy cp "$repo_root"/MovieFolderPosters/Shared/Processing/Collections/*.swift \
  "$temp_root/Sources/MovieFolderPosters/"
rtk cp "$repo_root/MovieFolderPosters/MovieFolderPostersTests/Features/Installation/InstallationReadinessTests.swift" \
  "$temp_root/Tests/MovieFolderPostersTests/"
rtk cp "$repo_root/MovieFolderPosters/Shared/Configuration/DirectoryConfiguration.swift" \
  "$repo_root/MovieFolderPosters/Shared/Configuration/ConfigurationRepository.swift" \
  "$repo_root/MovieFolderPosters/Shared/Configuration/SharedEnvironment.swift" \
  "$temp_root/Sources/MovieFolderPosters/"

rtk cat > "$temp_root/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import Foundation
import PackageDescription

let repoRoot = ProcessInfo.processInfo.environment["MFP_REPO_ROOT"]!

let package = Package(
    name: "InstallationReadinessHarness",
    platforms: [.macOS("26.5")],
    products: [.library(name: "MovieFolderPosters", targets: ["MovieFolderPosters"])],
    dependencies: [
        .package(path: repoRoot + "/Packages/FileSystem"),
        .package(path: repoRoot + "/Packages/Persistence")
    ],
    targets: [
        .target(name: "MovieFolderPosters", dependencies: [
            .product(name: "FileSystem", package: "FileSystem"),
            .product(name: "Persistence", package: "Persistence")
        ]),
        .testTarget(name: "MovieFolderPostersTests", dependencies: [
            "MovieFolderPosters",
            .product(name: "Persistence", package: "Persistence")
        ])
    ],
    swiftLanguageModes: [.v6]
)
SWIFT

rtk env \
  MFP_REPO_ROOT="$repo_root" \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/mfp-install-module-cache \
  CLANG_MODULE_CACHE_PATH=/tmp/mfp-install-clang-cache \
  swift test --package-path "$temp_root" --disable-sandbox \
    --cache-path /tmp/mfp-install-cache \
    --config-path /tmp/mfp-install-config \
    --security-path /tmp/mfp-install-security
