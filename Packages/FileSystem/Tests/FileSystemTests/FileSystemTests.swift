import Darwin
import Foundation
import Testing

@testable import FileSystem

/// Exercises directory snapshots, access probes, and symlink-safe cache operations.
struct FileSystemTests {
  /// Scenario: candidates include only immediate visible real directories.
  @Test func candidatesIncludeOnlyImmediateVisibleRealDirectories() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let movie = root.appendingPathComponent("Movie", isDirectory: true)
    try FileManager.default.createDirectory(at: movie, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(
      at: movie.appendingPathComponent("Nested"), withIntermediateDirectories: false
    )
    try Data("file".utf8).write(to: root.appendingPathComponent("movie.mkv"))
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".Hidden"), withIntermediateDirectories: false
    )
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("Linked"), withDestinationURL: movie
    )

    let candidates = try FileSystemService().candidates(in: root)
    #expect(candidates.map(\.name) == ["Movie"])
    #expect(candidates[0].identity.isEmpty == false)
    #expect(candidates[0].fingerprint.isEmpty == false)
    #expect(candidates[0].hasCustomIcon == false)
  }

  /// Scenario: inventory reports visible directories and excludes files, links, and hidden entries.
  @Test func inventoryIncludesOnlyVisibleImmediateDirectories() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let movie = root.appendingPathComponent("Movie", isDirectory: true)
    try FileManager.default.createDirectory(at: movie, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(
      at: movie.appendingPathComponent("Nested"), withIntermediateDirectories: false
    )
    try Data("file".utf8).write(to: root.appendingPathComponent("movie.mkv"))
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".Hidden"), withIntermediateDirectories: false
    )
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("Linked"), withDestinationURL: movie
    )

    let inventory = try FileSystemService().inventory(in: root)
    #expect(inventory.isComplete)
    #expect(inventory.members.map(\.name) == ["Movie"])
    #expect(inventory.members[0].candidate?.identity.isEmpty == false)
    #expect(inventory.members[0].issue == .none)
  }

  /// Scenario: strict poster inspection returns the current unowned state without mutation.
  @Test func strictPosterInspectionReportsNoIconAndSuppression() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("Movie"), withIntermediateDirectories: false
    )

    let inspection = try FileSystemService().inspectPoster(toChild: "Movie", in: root)
    #expect(inspection.ownership == .none)
    #expect(inspection.appearance == .none)
    #expect(!inspection.isSuppressed)
  }

  /// Scenario: strict poster inspection rejects a replacement directory identity.
  @Test func strictPosterInspectionRejectsChangedIdentity() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let movie = root.appendingPathComponent("Movie", isDirectory: true)
    try FileManager.default.createDirectory(at: movie, withIntermediateDirectories: false)
    let identity = try FileSystemService().readCurrentState(ofChild: "Movie", in: root).identity
    try FileManager.default.removeItem(at: movie)
    try FileManager.default.createDirectory(at: movie, withIntermediateDirectories: false)

    #expect(throws: DirectoryAccessError.self) {
      try FileSystemService().inspectPoster(toChild: "Movie", in: root, expectedIdentity: identity)
    }
  }

  /// Scenario: candidate fingerprint ignores directory contents and modification time.
  @Test func candidateFingerprintIgnoresDirectoryContentsAndModificationTime() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let movie = root.appendingPathComponent("Movie", isDirectory: true)
    try FileManager.default.createDirectory(at: movie, withIntermediateDirectories: false)
    let service = FileSystemService()
    let before = try service.readCurrentState(ofChild: "Movie", in: root)
    try Data("new content".utf8).write(to: movie.appendingPathComponent("new-file"))
    let after = try service.readCurrentState(ofChild: "Movie", in: root)

    #expect(after.identity == before.identity)
    #expect(after.fingerprint == before.fingerprint)
  }

  /// Scenario: snapshot rejects stale name and symlink.
  @Test func snapshotRejectsStaleNameAndSymlink() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("Real", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("Link"), withDestinationURL: real
    )
    let service = FileSystemService()
    #expect(throws: DirectoryAccessError.self) { try service.readCurrentState(ofChild: "Missing", in: root) }
    #expect(throws: DirectoryAccessError.self) { try service.readCurrentState(ofChild: "Link", in: root) }
    #expect(throws: DirectoryAccessError.self) { try service.readCurrentState(ofChild: "../Real", in: root) }
  }

  /// Scenario: cached data round trips and missing read returns nil.
  @Test func cachedDataRoundTripsAndMissingReadReturnsNil() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = root.appendingPathComponent("Cache", isDirectory: true)
    let service = FileSystemService()
    #expect(try service.readData(named: "poster-1", in: cache) == .none)
    let expected = Data("poster bytes".utf8)
    try service.writeData(expected, named: "poster-1", in: cache)
    #expect(try service.readData(named: "poster-1", in: cache) == expected)
    #expect(try service.readData(named: "poster-1", in: cache) == expected)
  }

  /// Scenario: cached data rejects unsafe names and symlink scope.
  @Test func cachedDataRejectsUnsafeNamesAndSymlinkScope() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = root.appendingPathComponent("Cache", isDirectory: true)
    let outside = root.appendingPathComponent("Outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    let link = root.appendingPathComponent("LinkedCache")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let service = FileSystemService()

    for name in ["../escape", ".hidden", "a/b", "a\\b", ""] {
      #expect(throws: DirectoryAccessError.self) { try service.writeData(Data(), named: name, in: cache) }
    }
    #expect(throws: DirectoryAccessError.self) { try service.writeData(Data(), named: "item", in: link) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
  }

  /// Scenario: cached data rejects final directory symlink and non regular entries.
  @Test func cachedDataRejectsFinalDirectorySymlinkAndNonRegularEntries() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.appendingPathComponent("Outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    let linkedCache = root.appendingPathComponent("LinkedCache")
    try FileManager.default.createSymbolicLink(at: linkedCache, withDestinationURL: outside)
    let service = FileSystemService()
    #expect(throws: DirectoryAccessError.self) {
      try service.writeData(Data("outside".utf8), named: "item", in: linkedCache)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)

    let cache = root.appendingPathComponent("Cache", isDirectory: true)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(
      at: cache.appendingPathComponent("item"), withIntermediateDirectories: false
    )
    #expect(throws: DirectoryAccessError.self) { try service.readData(named: "item", in: cache) }
    #expect(throws: DirectoryAccessError.self) { try service.writeData(Data(), named: "item", in: cache) }
  }

  /// Scenario: cached data read does not block on pipe entry.
  @Test func cachedDataReadDoesNotBlockOnPipeEntry() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = root.appendingPathComponent("Cache", isDirectory: true)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
    let pipePath = cache.appendingPathComponent("pipe").path
    #expect(mkfifo(pipePath, mode_t(0o600)) == 0)

    #expect(throws: DirectoryAccessError.self) { try FileSystemService().readData(named: "pipe", in: cache) }
  }

  /// Scenario: cached data rejects symlinked ancestor.
  @Test func cachedDataRejectsSymlinkedAncestor() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.appendingPathComponent("Outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    let alias = root.appendingPathComponent("Alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
    let escapedCache = alias.appendingPathComponent("Cache", isDirectory: true)

    #expect(throws: DirectoryAccessError.self) {
      try FileSystemService().writeData(Data("escape".utf8), named: "item", in: escapedCache)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
  }

  /// Scenario: rejects non file directory url.
  @Test func rejectsNonFileDirectoryURL() throws {
    let directory = try #require(URL(string: "https://example.com/movies"))

    do {
      _ = try FileSystemService().makeDirectoryBookmark(for: directory)
      Issue.record("Expected a non-file URL to be rejected")
    } catch DirectoryAccessError.invalidDirectory {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  /// Scenario: rejects regular file as directory.
  @Test func rejectsRegularFileAsDirectory() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("movie.mkv")
    try Data().write(to: file)

    do {
      _ = try FileSystemService().makeDirectoryBookmark(for: file)
      Issue.record("Expected a regular file to be rejected")
    } catch DirectoryAccessError.invalidDirectory {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  /// Scenario: rejects symbolic link to directory.
  @Test func rejectsSymbolicLinkToDirectory() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("Movies", isDirectory: true)
    let link = root.appendingPathComponent("MoviesLink")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)

    do {
      _ = try FileSystemService().makeDirectoryBookmark(for: link)
      Issue.record("Expected a symbolic-link directory to be rejected")
    } catch DirectoryAccessError.invalidDirectory {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  /// Scenario: malformed bookmark does not run operation.
  @Test func malformedBookmarkDoesNotRunOperation() {
    var operationRan = false

    do {
      try FileSystemService().withDirectoryAccess(bookmark: Data([0, 1, 2])) { _ in operationRan = true }
      Issue.record("Expected malformed bookmark data to be rejected")
    } catch {
      #expect(!operationRan)
    }
    #expect(!operationRan)
  }

  /// Scenario: access probe preserves existing contents.
  @Test func accessProbePreservesExistingContents() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let movie = root.appendingPathComponent("movie.mkv")
    let expected = Data("Unchanged movie fixture".utf8)
    try expected.write(to: movie)

    try FileSystemService().verifyReadWriteAccess(in: root)

    #expect(try Data(contentsOf: movie) == expected)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["movie.mkv"])
  }

  /// Scenario: access probe rejects regular file without modifying it.
  @Test func accessProbeRejectsRegularFileWithoutModifyingIt() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let movie = root.appendingPathComponent("movie.mkv")
    let expected = Data("Unchanged movie fixture".utf8)
    try expected.write(to: movie)

    #expect(throws: DirectoryAccessError.self) { try FileSystemService().verifyReadWriteAccess(in: movie) }
    #expect(try Data(contentsOf: movie) == expected)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["movie.mkv"])
  }

  /// Creates an isolated root for filesystem service tests.
  /// - Returns: The newly created root URL.
  /// - Throws: A filesystem error when the directory cannot be created.
  private func makeTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

    return root
  }
}
