#!/bin/bash
set -euo pipefail
source "$(rtk proxy dirname "$0")/test-support/common-tests.sh"
common_swift test --filter "ReleaseNameParserTests"
