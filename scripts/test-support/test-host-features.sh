#!/bin/bash
set -euo pipefail
source "$(rtk proxy dirname "$BASH_SOURCE")/common-tests.sh"
host_harness=$(rtk proxy mktemp -d "${TMPDIR:-/tmp}/MovieFolderPosters-HostFeatures.XXXXXX")
trap 'rtk proxy rm -rf "$host_harness"' EXIT
rtk proxy python3 "$common_repository/scripts/test-support/prepare-application-harness.py" \
  --repository "$common_repository" --directory "$host_harness" >/dev/null
SWIFTPM_MODULECACHE_OVERRIDE="$common_cache/module-cache" \
CLANG_MODULE_CACHE_PATH="$common_cache/clang-cache" \
  rtk proxy swift test --package-path "$host_harness" --disable-sandbox \
    --cache-path "$common_cache/cache" --config-path "$common_cache/config" \
    --security-path "$common_cache/security" --no-parallel --filter "${1:-MovieFolderPostersTests}"
