"""Behavioral checks for production-source accounting and a strict coverage threshold."""

import importlib.util
import json
from pathlib import Path
import tempfile
import subprocess
import sys
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "coverage-report.py"


class CoverageReportTests(unittest.TestCase):
    """Catch false passes caused by rounding, missing data, or incorrect source accounting."""

    @classmethod
    def setUpClass(cls):
        specification = importlib.util.spec_from_file_location("coverage_report", MODULE_PATH)
        cls.report = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(cls.report)

    def test_exactly_ninety_percent_fails_but_fraction_above_passes(self):
        result = {"App": {"covered_lines": 90, "executable_lines": 100, "complete": True}}
        self.assertEqual(len(self.report.coverage_failures(result, {"App"})), 1)
        result["App"].update(covered_lines=9001, executable_lines=10000)
        self.assertEqual(self.report.coverage_failures(result, {"App"}), [])

    def test_missing_incomplete_and_invalid_reports_cannot_pass(self):
        self.assertEqual(len(self.report.coverage_failures({}, {"App"})), 1)
        for covered, total, complete in [(99, 100, False), (0, 0, True), (101, 100, True), (-1, 1, True)]:
            with self.subTest(covered=covered, total=total, complete=complete):
                result = {"App": {"covered_lines": covered, "executable_lines": total, "complete": complete}}
                self.assertEqual(len(self.report.coverage_failures(result, {"App"})), 1)

    def test_copied_sources_map_back_without_counting_dependencies_or_tests(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            original = root / "Production"
            copied = root / "Harness"
            original.mkdir()
            copied.mkdir()
            (original / "Service.swift").write_text("func perform() { print(1) }\n")
            (copied / "Service.swift").write_text((original / "Service.swift").read_text())
            records = [self.file_record(copied / "Service.swift", 91, 100),
                       self.file_record(root / "Tests.swift", 1000, 1000)]
            export = root / "coverage.json"
            export.write_text(json.dumps({"data": [{"files": records}]}))
            result = self.report.component_coverage(export, original, copied)
            self.assertEqual((result["covered_lines"], result["executable_lines"]), (91, 100))
            self.assertTrue(result["complete"])
            self.assertEqual(result["files"][0]["source"], str(original / "Service.swift"))

    def test_missing_executable_file_is_reported_incomplete(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / "Untested.swift").write_text("func untested() { print(1) }\n")
            export = root / "coverage.json"
            export.write_text('{"data":[{"files":[]}]}')
            result = self.report.component_coverage(export, root, root)
            self.assertFalse(result["complete"])
            self.assertEqual(result["missing_sources"], [str(root / "Untested.swift")])

    def test_declaration_only_enum_is_accounted_for_without_inventing_executable_lines(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            enum = root / "State.swift"
            enum.write_text("import Foundation\n/// Stable states.\npublic enum State: Sendable {\n  case ready, busy\n}\n")
            export = root / "coverage.json"
            export.write_text('{"data":[{"files":[]}]}')
            result = self.report.component_coverage(export, root, root)
            self.assertTrue(result["complete"])
            self.assertEqual(result["declaration_only_sources"], [str(enum)])
            self.assertEqual(result["executable_lines"], 0)

    def test_duplicate_records_are_not_added_twice_and_conflicting_duplicates_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source = root / "Service.swift"
            source.write_text("func perform() { print(1) }\n")
            record = self.file_record(source, 91, 100)
            export = root / "coverage.json"
            export.write_text(json.dumps({"data": [{"files": [record, record]}]}))
            self.assertEqual(self.report.component_coverage(export, root, root)["executable_lines"], 100)
            export.write_text(json.dumps({"data": [{"files": [record, self.file_record(source, 92, 100)]}]}))
            with self.assertRaises(ValueError):
                self.report.component_coverage(export, root, root)

    def test_stored_property_record_without_explicit_code_has_no_executable_lines(self):
        source = '''import Foundation
        public struct Entry<Event: Codable & Sendable>: Codable, Sendable, Identifiable {
          public let id: UUID
          public let event: Event
        }
        '''
        self.assertTrue(self.report.declaration_only(source))
        for executable_member in [
            'init() {}', 'var count: Int { 1 }', 'let count: Int = calculate()',
            'var count: Int { didSet { print(count) } }', 'func perform() {}'
        ]:
            with self.subTest(member=executable_member):
                self.assertFalse(self.report.declaration_only('struct Entry { ' + executable_member + ' }'))

    def test_enum_with_associated_value_cases_has_no_executable_lines(self):
        source = '''import Foundation
        public enum RetryResult: Sendable, Equatable {
          case attempted(ProcessingSummary, stopSelection: Bool)
          case notEligible
          case waiting(until: Date)
        }
        '''
        self.assertTrue(self.report.declaration_only(source))

    def test_malformed_coverage_cannot_be_treated_as_empty_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            export = root / "coverage.json"
            export.write_text('{"unexpected":true}')
            with self.assertRaises(ValueError):
                self.report.component_coverage(export, root, root)

    def test_stale_copied_source_cannot_claim_current_coverage(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source = root / "production"
            copied = root / "copied"
            source.mkdir()
            copied.mkdir()
            (source / "Service.swift").write_text("func current() { print(1) }\n")
            (copied / "Service.swift").write_text("func old() { print(1) }\n")
            export = root / "coverage.json"
            export.write_text(json.dumps({"data": [{"files": [self.file_record(copied / "Service.swift", 1, 1)]}]}))
            with self.assertRaisesRegex(ValueError, "stale"):
                self.report.component_coverage(export, source, copied)

    def test_project_aggregate_counts_both_host_and_finder(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.fixture_manifest(Path(directory).resolve())
            finder_export = Path(next(item["export"] for item in manifest["components"] if item["name"] == "Finder"))
            payload = json.loads(finder_export.read_text())
            payload["data"][0]["files"][0]["summary"]["lines"]["covered"] = 50
            finder_export.write_text(json.dumps(payload))
            report = self.report.create_report(manifest)
            self.assertEqual(report["components"]["Project"]["covered_lines"], 141)
            self.assertEqual(report["components"]["Project"]["executable_lines"], 200)
            self.assertFalse(report["passed"])

    def test_required_package_cannot_be_omitted_from_manifest_to_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.fixture_manifest(Path(directory).resolve())
            manifest["components"] = [item for item in manifest["components"] if item["name"] != "Network"]
            manifest["required_components"] = []
            report = self.report.create_report(manifest)
            self.assertFalse(report["passed"])
            self.assertTrue(any("Network" in message for message in report["failures"]))

    def test_failed_test_run_cannot_supply_passing_coverage(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.fixture_manifest(Path(directory).resolve())
            manifest["components"][0]["test_exit_code"] = 1
            with self.assertRaisesRegex(ValueError, "test execution"):
                self.report.create_report(manifest)

    def test_command_exit_status_enforces_the_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest = self.fixture_manifest(root)
            manifest_file = root / "manifest.json"
            output_file = root / "result.json"
            manifest_file.write_text(json.dumps(manifest))
            command = [sys.executable, str(MODULE_PATH), "--manifest", str(manifest_file), "--output", str(output_file)]
            passed = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(passed.returncode, 0, passed.stderr)
            self.assertTrue(json.loads(output_file.read_text())["passed"])
            missing = manifest["components"].pop()
            manifest_file.write_text(json.dumps(manifest))
            failed = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(failed.returncode, 1, failed.stderr)
            self.assertIn(missing["name"], failed.stderr)

    @classmethod
    def fixture_manifest(cls, root):
        components = []
        for name in ["Host", "Finder", "Network", "FileSystem", "Persistence", "Log", "MovieFolderCommon",
                     "MovieFolderParsing"]:
            source_root = root / name
            source_root.mkdir()
            source = source_root / "Service.swift"
            source.write_text("func perform() { print(1) }\n")
            export = root / (name + ".json")
            export.write_text(json.dumps({"data": [{"files": [cls.file_record(source, 91, 100)]}]}))
            components.append({"name": name, "source_root": str(source_root), "compiled_root": str(source_root),
                               "export": str(export), "test_exit_code": 0})
        return {"components": components, "required_components": ["Project", "Network", "FileSystem",
                                                                 "Persistence", "Log", "MovieFolderCommon",
                                                                 "MovieFolderParsing"]}

    @staticmethod
    def file_record(path, covered, total):
        return {"filename": str(path), "summary": {"lines": {"covered": covered, "count": total}}}


if __name__ == "__main__":
    unittest.main()
