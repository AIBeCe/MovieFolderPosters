#!/bin/bash
set -euo pipefail
rtk proxy bash "$(rtk proxy dirname "$0")/test-support/test-host-features.sh" "ConfigurationViewModelTests"
