#!/bin/bash
set -euo pipefail
source "$(rtk proxy dirname "$0")/test-support/common-tests.sh"
# Common configuration and scheduling behavior migrated to their package test target.
common_swift test --filter "DirectoryConfigurationTests|CredentialRevisionTests|DirectoryObservationSchedulerTests" ${CONFIGURATION_TEST_FLAGS:-}
rtk proxy bash "$(rtk proxy dirname "$0")/test-support/test-host-features.sh" "DirectoryConfigurationServiceTests"
