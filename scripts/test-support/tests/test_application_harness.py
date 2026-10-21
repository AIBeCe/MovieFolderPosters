"""Check safe harness ownership and complete source copying without launching AppKit."""

import importlib.util
from pathlib import Path
import tempfile
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "prepare-application-harness.py"


class ApplicationHarnessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        specification = importlib.util.spec_from_file_location("application_harness", MODULE_PATH)
        cls.harness = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(cls.harness)

    def test_includes_app_delegate_finder_and_tests_without_excluding_executable_lines(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            repository = self.fixture_repository(root)
            output = root / "harness"
            self.harness.prepare(repository, output)
            original = (repository / "MovieFolderPosters/MovieFolderPosters/Application/AppDelegate.swift").read_text()
            copied = (output / "Sources/MovieFolderPosters/Application/AppDelegate.swift").read_text()
            self.assertEqual(copied, original.replace("@main\n", "\n"))
            self.assertEqual(copied.count("\n"), original.count("\n"))
            self.assertTrue((output / "Sources/MovieFolderFinder/Integration/FinderSync.swift").is_file())
            self.assertTrue((output / "Tests/MovieFolderFinderTests/FinderTests.swift").is_file())
            self.assertTrue((output / "Tests/MovieFolderPostersTests/Application/RootTests.swift").is_file())
            (output / "Sources/MovieFolderFinder/Stale.swift").write_text("stale")
            self.harness.prepare(repository, output)
            self.assertFalse((output / "Sources/MovieFolderFinder/Stale.swift").exists())

    def test_refuses_to_replace_an_unowned_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            repository = self.fixture_repository(root)
            output = root / "harness"
            output.mkdir()
            sentinel = output / "user.txt"
            sentinel.write_text("preserve")
            with self.assertRaisesRegex(ValueError, "unowned"):
                self.harness.prepare(repository, output)
            self.assertEqual(sentinel.read_text(), "preserve")

    @staticmethod
    def fixture_repository(root):
        repository = root / "repository"
        host = repository / "MovieFolderPosters/MovieFolderPosters"
        for name in ["Application", "Features", "UI", "Resources"]:
            (host / name).mkdir(parents=True)
        (host / "Application/AppDelegate.swift").write_text("import AppKit\n@main\nclass AppDelegate {}\n")
        finder = repository / "MovieFolderPosters/MovieFolderPostersFinder/Integration"
        finder.mkdir(parents=True)
        (finder / "FinderSync.swift").write_text("class FinderSync {}\n")
        host_tests = repository / "MovieFolderPosters/MovieFolderPostersTests/Application"
        host_tests.mkdir(parents=True)
        (host_tests / "RootTests.swift").write_text("import Testing\n")
        finder_tests = repository / "MovieFolderPosters/MovieFolderPostersFinderTests"
        finder_tests.mkdir(parents=True)
        (finder_tests / "FinderTests.swift").write_text("import Testing\n")
        for name in ["MovieFolderCommon", "MovieFolderParsing", "Network", "FileSystem", "Persistence", "Log"]:
            (repository / "Packages" / name).mkdir(parents=True)
        return repository


if __name__ == "__main__":
    unittest.main()
