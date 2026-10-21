#!/bin/bash
# Qualify real process death and stale recovery instances without user data or real provider requests.
set -euo pipefail
source "$(rtk proxy dirname "$0")/test-support/common-tests.sh"
recovery_probe=$(rtk proxy mktemp -d "${TMPDIR:-/tmp}/MovieFolderPosters-RecoveryProbe.XXXXXX")
trap 'rtk proxy rm -rf "$recovery_probe"' EXIT
rtk proxy mkdir -p "$recovery_probe/Sources/RecoveryProcessProbe"
rtk proxy cp "$common_repository/scripts/test-support/RecoveryProcessProbe/main.swift" \
  "$recovery_probe/Sources/RecoveryProcessProbe/"
for recovery_package in MovieFolderCommon MovieFolderParsing Network FileSystem Persistence Log; do
  rtk proxy ln -s "$common_repository/Packages/$recovery_package" "$recovery_probe/$recovery_package"
done
rtk proxy tee "$recovery_probe/Package.swift" >/dev/null <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
  name: "RecoveryProcessProbe",
  platforms: [.macOS("26.5")],
  dependencies: [.package(path: "MovieFolderCommon"), .package(path: "Persistence")],
  targets: [.executableTarget(name: "RecoveryProcessProbe", dependencies: ["MovieFolderCommon", "Persistence"])],
  swiftLanguageModes: [.v6])
SWIFT
SWIFTPM_MODULECACHE_OVERRIDE="$common_cache/module-cache" \
CLANG_MODULE_CACHE_PATH="$common_cache/clang-cache" \
  rtk proxy swift build --package-path "$recovery_probe" --disable-sandbox \
    --cache-path "$common_cache/cache" --config-path "$common_cache/config" \
    --security-path "$common_cache/security" --product RecoveryProcessProbe
recovery_binary="$recovery_probe/.build/debug/RecoveryProcessProbe"
rtk proxy python3 "$common_repository/scripts/test-support/recovery-process-probe.py" "$recovery_binary"
