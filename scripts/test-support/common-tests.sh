#!/bin/bash
# Build the real Common package with writable caches while preserving caller test controls.
common_repository=$(cd "$(rtk proxy dirname "$BASH_SOURCE")/../.." && pwd)
common_package="$common_repository/Packages/MovieFolderCommon"
common_cache="$common_package/.build/verification"
common_swift() {
  SWIFTPM_MODULECACHE_OVERRIDE="$common_cache/module-cache" \
  CLANG_MODULE_CACHE_PATH="$common_cache/clang-cache" \
    rtk proxy swift "$@" --package-path "$common_package" --disable-sandbox \
      --cache-path "$common_cache/cache" --config-path "$common_cache/config" \
      --security-path "$common_cache/security"
}
