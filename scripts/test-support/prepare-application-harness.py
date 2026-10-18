#!/usr/bin/env python3
"""Prepare isolated host/Finder library targets from every production source, without launching either app."""

import argparse
import json
from pathlib import Path
import shutil
import tempfile


def prepare(repository, directory):
    """Refresh only this tool's marked harness and preserve source line locations."""
    repository = repository.resolve()
    directory = directory.resolve()
    marker = directory / ".movie-folder-posters-harness"
    if directory.exists() and any(directory.iterdir()):
        if not marker.exists() or marker.read_text() != str(repository):
            raise ValueError(f"Refusing to replace an unowned harness: {directory}")
    directory.mkdir(parents=True, exist_ok=True)
    marker.write_text(str(repository))
    for component in ["Sources", "Tests"]:
        target = directory / component
        if target.exists():
            shutil.rmtree(target)
        target.mkdir()
    host = directory / "Sources/MovieFolderPosters"
    host.mkdir()
    for name in ["Application", "Features", "UI", "Resources"]:
        shutil.copytree(repository / "MovieFolderPosters/MovieFolderPosters" / name, host / name)
    delegate = host / "Application/AppDelegate.swift"
    original = delegate.read_text()
    if original.splitlines().count("@main") != 1:
        raise ValueError("Expected exactly one host @main attribute; refusing an unverified entrypoint transformation")
    # Only the attribute is blanked; executable source and its original line numbers remain unchanged.
    delegate.write_text("\n".join("" if line == "@main" else line for line in original.split("\n")))
    finder = directory / "Sources/MovieFolderFinder"
    shutil.copytree(repository / "MovieFolderPosters/MovieFolderPostersFinder", finder)
    host_tests = directory / "Tests/MovieFolderPostersTests"
    host_tests.mkdir()
    for source in (repository / "MovieFolderPosters/MovieFolderPostersTests").iterdir():
        if source.is_dir():
            shutil.copytree(source, host_tests / source.name)
        elif source.suffix == ".swift":
            shutil.copy2(source, host_tests / source.name)
    finder_tests = repository / "MovieFolderPosters/MovieFolderPostersFinderTests"
    has_finder_tests = finder_tests.exists() and any(finder_tests.rglob("*.swift"))
    if has_finder_tests:
        shutil.copytree(finder_tests, directory / "Tests/MovieFolderFinderTests")
    packages = ["MovieFolderCommon", "Network", "FileSystem", "Persistence", "Log"]
    for package in packages:
        link = directory / package
        if not link.exists():
            link.symlink_to(repository / "Packages" / package, target_is_directory=True)
    dependencies = ", ".join(f'.package(path: "{name}")' for name in packages)
    names = ", ".join(f'"{name}"' for name in packages)
    finder_target = f''',
    .testTarget(name: "MovieFolderFinderTests", dependencies: ["MovieFolderFinder", {names}],
                swiftSettings: [.enableUpcomingFeature("NonisolatedNonsendingByDefault")])''' if has_finder_tests else ""
    manifest = f'''// swift-tools-version: 6.2
import PackageDescription
let package = Package(
  name: "ApplicationVerification",
  platforms: [.macOS("26.5")],
  dependencies: [{dependencies}],
  targets: [
    .target(name: "MovieFolderPosters", dependencies: [{names}],
            exclude: ["Resources/Assets.xcassets", "Resources/Base.lproj"],
            resources: [.process("Resources/PreviewPoster.png")],
            swiftSettings: [.defaultIsolation(MainActor.self),
                            .enableUpcomingFeature("InferIsolatedConformances"),
                            .enableUpcomingFeature("NonisolatedNonsendingByDefault")]),
    .target(name: "MovieFolderFinder", dependencies: [{names}],
            exclude: ["Configuration"], resources: [.process("Resources")],
            swiftSettings: [.enableUpcomingFeature("NonisolatedNonsendingByDefault")]),
    .testTarget(name: "MovieFolderPostersTests", dependencies: ["MovieFolderPosters", {names}],
                resources: [.process("Resources")],
                swiftSettings: [.enableUpcomingFeature("NonisolatedNonsendingByDefault")]){finder_target}
  ], swiftLanguageModes: [.v6])
'''
    (directory / "Package.swift").write_text(manifest)
    mapping = {"Host": {"source_root": str(repository / "MovieFolderPosters/MovieFolderPosters"),
                         "compiled_root": str(host)},
               "Finder": {"source_root": str(repository / "MovieFolderPosters/MovieFolderPostersFinder"),
                           "compiled_root": str(finder)}}
    (directory / "production-source-map.json").write_text(json.dumps(mapping, indent=2) + "\n")
    return directory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--directory", type=Path)
    arguments = parser.parse_args()
    directory = arguments.directory or Path(tempfile.mkdtemp(prefix="MovieFolderPosters-ApplicationTests."))
    print(prepare(arguments.repository, directory))


if __name__ == "__main__":
    main()
