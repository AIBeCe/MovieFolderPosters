#!/usr/bin/env python3
"""Account for every production Swift source and enforce exact, component-level line coverage."""

import argparse
import json
from pathlib import Path
import re
import sys


REQUIRED_COMPONENTS = {"Project", "Network", "FileSystem", "Persistence", "Log", "MovieFolderCommon"}


def coverage_failures(results, required_components):
    """Reject missing/invalid data and coverage at or below ninety percent without rounding."""
    failures = []
    for name in sorted(required_components):
        result = results.get(name)
        if result is None or not result.get("complete", False):
            failures.append(f"{name}: complete coverage data is missing")
            continue
        covered = result["covered_lines"]
        executable = result["executable_lines"]
        if executable <= 0 or not 0 <= covered <= executable:
            failures.append(f"{name}: invalid coverage totals")
        elif covered * 100 <= executable * 90:
            failures.append(f"{name}: {covered}/{executable} lines; coverage must exceed 90%")
    return failures


def declaration_only(source):
    """Recognize enums and stored-property records without explicit executable code."""
    text = re.sub(r"/\*.*?\*/", "", source, flags=re.DOTALL)
    text = re.sub(r"//[^\n]*", "", text)
    imports = r"(?:\s*import\s+[\w.]+\s*)*"
    modifiers = r"(?:(?:public|internal|private|fileprivate|nonisolated|package)\s+)*"
    enum = modifiers + r"enum\s+\w+(?:\s*:\s*[\w,\s]+)?\s*\{\s*(?:case\s+[^{}\n]+\s*)*\}\s*"
    # Synthesized Codable/memberwise functions have no source executable lines. Reject defaults,
    # observers, methods, explicit initializers, and computed properties instead of hiding them.
    stored_property = modifiers + r"(?:let|var)\s+\w+\s*:\s*[\w.?]+\s*"
    record = (modifiers + r"struct\s+\w+(?:\s*<[\w\s:,&]+>)?(?:\s*:\s*[\w,\s]+)?\s*\{\s*"
              + "(?:" + stored_property + ")+" + r"\}\s*")
    return re.fullmatch(imports + "(?:" + enum + "|" + record + ")+", text.strip()) is not None


def component_coverage(export_path, source_root, compiled_root):
    """Map compiler-reported files to real source, excluding other targets but never missing code."""
    source_root = Path(source_root).resolve()
    compiled_root = Path(compiled_root).resolve()
    expected = {path.resolve() for path in source_root.rglob("*.swift")}
    if not expected:
        raise ValueError(f"No production sources found in {source_root}")
    document = json.loads(Path(export_path).read_text())
    if not isinstance(document.get("data"), list) or not document["data"]:
        raise ValueError(f"Malformed compiler coverage export: {export_path}")
    records = {}
    for section in document["data"]:
        if not isinstance(section.get("files"), list):
            raise ValueError(f"Missing compiler file records: {export_path}")
        for item in section["files"]:
            path = Path(item["filename"]).resolve()
            if not path.is_relative_to(compiled_root):
                continue
            original = source_root / path.relative_to(compiled_root)
            if original not in expected:
                raise ValueError(f"Unexpected/stale production source: {original}")
            if original != path:
                expected_text = original.read_text()
                if original.name == "AppDelegate.swift":
                    expected_text = "\n".join("" if line == "@main" else line
                                              for line in expected_text.split("\n"))
                if path.read_text() != expected_text:
                    raise ValueError(f"Compiled source snapshot is stale: {original}")
            lines = item["summary"]["lines"]
            covered, count = lines["covered"], lines["count"]
            if type(covered) is not int or type(count) is not int or not 0 <= covered <= count:
                raise ValueError(f"Invalid compiler line totals for {original}")
            if original in records and records[original] != (covered, count):
                raise ValueError(f"Conflicting duplicate coverage for {original}; merge profiles before reporting")
            records[original] = covered, count
    missing = []
    declaration_only_sources = []
    for path in sorted(expected - records.keys()):
        if declaration_only(path.read_text()):
            declaration_only_sources.append(str(path))
        else:
            missing.append(str(path))
    files = [{"source": str(path), "covered_lines": covered, "executable_lines": count}
             for path, (covered, count) in sorted(records.items())]
    return {
        "covered_lines": sum(item["covered_lines"] for item in files),
        "executable_lines": sum(item["executable_lines"] for item in files),
        "complete": not missing,
        "missing_sources": missing,
        "declaration_only_sources": declaration_only_sources,
        "files": files
    }


def create_report(manifest):
    """Build package and application aggregates from separately instrumented production targets."""
    results = {}
    for entry in manifest["components"]:
        name = entry["name"]
        if name in results:
            raise ValueError(f"Duplicate component: {name}")
        if entry.get("test_exit_code") != 0:
            raise ValueError(f"{name}: test execution did not succeed")
        results[name] = component_coverage(entry["export"], entry["source_root"], entry["compiled_root"])
    required = set(manifest["required_components"]) | REQUIRED_COMPONENTS
    if not {"Host", "Finder"}.issubset(results):
        raise ValueError("Both Host and Finder are required for complete project coverage")
    targets = [results["Host"], results["Finder"]]
    results["Project"] = {
        "covered_lines": sum(target["covered_lines"] for target in targets),
        "executable_lines": sum(target["executable_lines"] for target in targets),
        "complete": all(target["complete"] for target in targets),
        "missing_sources": [path for target in targets for path in target["missing_sources"]]
    }
    failures = coverage_failures(results, required)
    return {"schema_version": 1, "components": results, "failures": failures, "passed": not failures}


def main():
    """Write a durable JSON report and return failure when any required component misses its gate."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        report = create_report(json.loads(arguments.manifest.read_text()))
    except (ValueError, KeyError, TypeError, OSError) as error:
        print(f"Coverage collection failed: {error}", file=sys.stderr)
        return 2
    arguments.output.write_text(json.dumps(report, indent=2) + "\n")
    for name, component in report["components"].items():
        covered, total = component["covered_lines"], component["executable_lines"]
        percentage = f"{covered / total:.2%}" if total else "unavailable"
        print(f"{name}: {covered}/{total} lines ({percentage}); complete={component['complete']}")
    for failure in report["failures"]:
        print(f"FAIL: {failure}", file=sys.stderr)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
