#!/bin/bash
set -euo pipefail
parser_repository=$(cd "$(rtk proxy dirname "$0")/.." && pwd)
parser_package="$parser_repository/Packages/MovieFolderParsing"
parser_cache="$parser_package/.build/verification"
SWIFTPM_MODULECACHE_OVERRIDE="$parser_cache/module-cache" \
CLANG_MODULE_CACHE_PATH="$parser_cache/clang-cache" \
  rtk proxy swift test --package-path "$parser_package" --filter "ReleaseNameParserTests" \
    --disable-sandbox --cache-path "$parser_cache/cache" --config-path "$parser_cache/config" \
    --security-path "$parser_cache/security"
