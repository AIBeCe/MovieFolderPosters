#!/bin/bash
# Developer-only, explicitly invoked offline maintenance. Never starts or stops application processes.
set -euo pipefail
if [[ "$#" != 1 || "$1" != "--older-processes-stopped" ]]; then
  rtk proxy cat >&2 <<'USAGE'
Usage: scripts/migrate-collection-processing-state.sh --older-processes-stopped

First quit every MovieFolderPosters app and disable its Finder extension so older processes cannot relaunch.
The assertion confirms that the operator has done this and will keep them stopped throughout maintenance.
The tool also takes one process-list snapshot immediately before migrating and refuses known running executables.
It does not quit applications, disable extensions, alter registrations, or migrate movie folders.
USAGE
  exit 2
fi
source "$(rtk proxy dirname "$0")/test-support/common-tests.sh"
maintenance_package=$(rtk proxy mktemp -d "${TMPDIR:-/tmp}/MovieFolderPosters-NamespaceMaintenance.XXXXXX")
trap 'rtk proxy rm -rf "$maintenance_package"' EXIT
rtk proxy mkdir -p "$maintenance_package/Sources/CollectionProcessingNamespaceMaintenance"
rtk proxy cp "$common_repository/scripts/test-support/CollectionProcessingNamespaceMaintenance/main.swift" \
  "$maintenance_package/Sources/CollectionProcessingNamespaceMaintenance/"
for package in MovieFolderCommon Network FileSystem Persistence Log; do
  rtk proxy ln -s "$common_repository/Packages/$package" "$maintenance_package/$package"
done
rtk proxy tee "$maintenance_package/Package.swift" >/dev/null <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
  name: "CollectionProcessingNamespaceMaintenance",
  platforms: [.macOS("26.5")],
  dependencies: [.package(path: "MovieFolderCommon")],
  targets: [.executableTarget(name: "CollectionProcessingNamespaceMaintenance", dependencies: ["MovieFolderCommon"])],
  swiftLanguageModes: [.v6])
SWIFT
SWIFTPM_MODULECACHE_OVERRIDE="$common_cache/module-cache" \
CLANG_MODULE_CACHE_PATH="$common_cache/clang-cache" \
  rtk proxy swift build --package-path "$maintenance_package" --disable-sandbox \
    --cache-path "$common_cache/cache" --config-path "$common_cache/config" \
    --security-path "$common_cache/security" --product CollectionProcessingNamespaceMaintenance
maintenance_bin=$(SWIFTPM_MODULECACHE_OVERRIDE="$common_cache/module-cache" \
  rtk proxy swift build --package-path "$maintenance_package" --show-bin-path)
rtk proxy "$maintenance_bin/CollectionProcessingNamespaceMaintenance" --older-processes-stopped
