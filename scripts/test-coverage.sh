#!/bin/bash
# Collect fresh production coverage for every local package and both application targets.
set -euo pipefail
coverage_repository=$(cd "$(rtk proxy dirname "$0")/.." && pwd)
coverage_run=$(rtk proxy mktemp -d "${TMPDIR:-/tmp}/MovieFolderPosters-Coverage.XXXXXX")
printf 'Coverage artifacts: %s\n' "$coverage_run"
export PYTHONDONTWRITEBYTECODE=1

coverage_test() {
  local component_name=$1
  local package_path=$2
  local component_output="$coverage_run/$component_name"
  rtk proxy mkdir -p "$component_output"
  printf 'Testing %s with production coverage...\n' "$component_name"
  if SWIFTPM_MODULECACHE_OVERRIDE="$component_output/module-cache" \
    CLANG_MODULE_CACHE_PATH="$component_output/clang-cache" \
    rtk proxy swift test --package-path "$package_path" --scratch-path "$component_output/scratch" \
      --cache-path "$component_output/cache" --config-path "$component_output/config" \
      --security-path "$component_output/security" --disable-sandbox --no-parallel \
      --enable-code-coverage >"$component_output/tests.log" 2>&1; then
    printf '%s tests passed.\n' "$component_name"
  else
    local test_status=$?
    printf '%s failed; inspect %s/tests.log\n' "$component_name" "$component_output" >&2
    exit "$test_status"
  fi
}

for coverage_package in "$coverage_repository"/Packages/*; do
  if [[ -f "$coverage_package/Package.swift" ]]; then
    coverage_test "$(rtk proxy basename "$coverage_package")" "$coverage_package"
  fi
done

rtk proxy python3 "$coverage_repository/scripts/test-support/prepare-application-harness.py" \
  --repository "$coverage_repository" --directory "$coverage_run/application" >/dev/null
coverage_test Application "$coverage_run/application"

rtk proxy python3 - "$coverage_repository" "$coverage_run" <<'PY'
import json
from pathlib import Path
import sys

repository, run = (Path(value).resolve() for value in sys.argv[1:])


def export_for(name):
    exports = list((run / name / "scratch").glob("**/codecov/*.json"))
    if len(exports) != 1:
        raise RuntimeError(f"Expected one fresh compiler coverage export for {name}, found {len(exports)}")
    return str(exports[0])


entries = []
required = ["Project"]
for package in sorted((repository / "Packages").iterdir()):
    if (package / "Package.swift").is_file():
        source_root = str(package / "Sources")
        entries.append({"name": package.name, "export": export_for(package.name),
                        "source_root": source_root, "compiled_root": source_root, "test_exit_code": 0})
        required.append(package.name)
mapping = json.loads((run / "application/production-source-map.json").read_text())
for name, roots in mapping.items():
    entries.append({"name": name, "export": export_for("Application"), **roots, "test_exit_code": 0})
(run / "manifest.json").write_text(json.dumps({"schema_version": 1, "components": entries,
                                             "required_components": required}, indent=2) + "\n")
PY

rtk proxy python3 "$coverage_repository/scripts/test-support/coverage-report.py" \
  --manifest "$coverage_run/manifest.json" --output "$coverage_run/coverage.json"
