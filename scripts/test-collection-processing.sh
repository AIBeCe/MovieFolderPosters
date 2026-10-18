#!/bin/bash
set -euo pipefail
source "$(rtk proxy dirname "$0")/test-support/common-tests.sh"
collection_probe=$(rtk proxy mktemp -d "${TMPDIR:-/tmp}/MovieFolderPosters-CollectionProbe.XXXXXX")
trap 'rtk proxy rm -rf "$collection_probe"' EXIT
rtk proxy mkdir -p "$collection_probe/Sources/CollectionProcessingProbe"
rtk proxy cp "$common_repository/scripts/test-support/CollectionProcessingProbe/main.swift" \
  "$collection_probe/Sources/CollectionProcessingProbe/"
for package in MovieFolderCommon Network FileSystem Persistence Log; do
  rtk proxy ln -s "$common_repository/Packages/$package" "$collection_probe/$package"
done
rtk proxy tee "$collection_probe/Package.swift" >/dev/null <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
  name: "CollectionProcessingProbe",
  platforms: [.macOS("26.5")],
  dependencies: [.package(path: "MovieFolderCommon"), .package(path: "Persistence")],
  targets: [.executableTarget(name: "CollectionProcessingProbe", dependencies: ["MovieFolderCommon", "Persistence"])],
  swiftLanguageModes: [.v6])
SWIFT
SWIFTPM_MODULECACHE_OVERRIDE="$common_cache/module-cache" \
CLANG_MODULE_CACHE_PATH="$common_cache/clang-cache" \
  rtk proxy swift build --package-path "$collection_probe" --disable-sandbox \
    --cache-path "$common_cache/cache" --config-path "$common_cache/config" \
    --security-path "$common_cache/security" --product CollectionProcessingProbe
collection_probe_bin=$(SWIFTPM_MODULECACHE_OVERRIDE="$common_cache/module-cache" \
  rtk proxy swift build --package-path "$collection_probe" --show-bin-path)
test_options=(--filter "CollectionProcessingModelTests|CollectionProcessingStoreTests")
if [[ "${COLLECTION_PROCESSING_BENCHMARK:-0}" == "1" ]]; then
  test_options=(--filter largeInventory32RecordCheckpointsReportEncodeAndEnvelopeCost)
fi
export COLLECTION_PROCESSING_PROBE_PATH="$collection_probe_bin/CollectionProcessingProbe"
common_swift test "${test_options[@]}"
