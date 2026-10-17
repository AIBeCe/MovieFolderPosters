import Foundation
import Testing

@testable import FileSystem

/// Exercises bookmark resolution, security-scoped access, and directory identity validation.
struct DirectoryAuthorizationTests {
  /// Scenario: implicit bookmark resolves to readable lease.
  @Test func implicitBookmarkResolvesToReadableLease() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("existing content".utf8).write(to: directory.appendingPathComponent("movie.mkv"))
    let service = FileSystemService()

    let bookmark = try service.makeTransferBookmark(for: directory)
    let lease = try service.acquireDirectoryAccess(bookmark: bookmark, securityScoped: false)

    #expect(lease.url.standardizedFileURL == directory.standardizedFileURL)
    #expect(try FileManager.default.contentsOfDirectory(atPath: lease.url.path) == ["movie.mkv"])
  }

  /// Scenario: transfer bookmark rejects file and symbolic link.
  @Test func transferBookmarkRejectsFileAndSymbolicLink() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("Movies", isDirectory: true)
    let file = root.appendingPathComponent("movie.mkv")
    let link = root.appendingPathComponent("MoviesLink")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try Data().write(to: file)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)

    #expect(throws: DirectoryAccessError.self) {
      try FileSystemService().makeTransferBookmark(for: file)
    }
    #expect(throws: DirectoryAccessError.self) {
      try FileSystemService().makeTransferBookmark(for: link)
    }
  }

  /// Scenario: malformed bookmark is rejected.
  @Test func malformedBookmarkIsRejected() {
    #expect(throws: DirectoryAccessError.self) {
      try FileSystemService().acquireDirectoryAccess(
        bookmark: Data([0, 1, 2]), securityScoped: false)
    }
  }

  /// Scenario: moved directory bookmark is rejected as stale.
  @Test func movedDirectoryBookmarkIsRejectedAsStale() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("Movies", isDirectory: true)
    let moved = root.appendingPathComponent("RenamedMovies", isDirectory: true)
    try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
    let bookmark = try FileSystemService().makeTransferBookmark(for: original)
    try FileManager.default.moveItem(at: original, to: moved)

    do {
      _ = try FileSystemService().acquireDirectoryAccess(
        bookmark: bookmark,
        securityScoped: false
      )
      Issue.record("Expected a moved directory bookmark to be rejected as stale")
    } catch DirectoryAccessError.staleBookmark {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  /// Scenario: moved directory bookmark can be accepted with matching expected identity.
  @Test func movedDirectoryBookmarkCanBeAcceptedWithMatchingExpectedIdentity() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("Movies", isDirectory: true)
    let moved = root.appendingPathComponent("RenamedMovies", isDirectory: true)
    try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
    let service = FileSystemService()
    let expectedIdentity = try service.persistentDirectoryIdentity(at: original)
    let bookmark = try service.makeTransferBookmark(for: original)
    try FileManager.default.moveItem(at: original, to: moved)

    let lease = try service.acquireDirectoryAccess(
      bookmark: bookmark,
      securityScoped: false,
      expectedIdentity: expectedIdentity
    )

    #expect(lease.url.standardizedFileURL == moved.standardizedFileURL)
  }

  /// Scenario: persistent directory identity survives rename and detects replacement.
  @Test func persistentDirectoryIdentitySurvivesRenameAndDetectsReplacement() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("Movies", isDirectory: true)
    let moved = root.appendingPathComponent("RenamedMovies", isDirectory: true)
    try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
    let service = FileSystemService()
    let identity = try service.persistentDirectoryIdentity(at: original)

    try FileManager.default.moveItem(at: original, to: moved)
    #expect(try service.persistentDirectoryIdentity(at: moved) == identity)

    try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
    #expect(try service.persistentDirectoryIdentity(at: original) != identity)
  }

  /// Scenario: moved directory bookmark rejects different expected identity.
  @Test func movedDirectoryBookmarkRejectsDifferentExpectedIdentity() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("Movies", isDirectory: true)
    let moved = root.appendingPathComponent("RenamedMovies", isDirectory: true)
    try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
    let service = FileSystemService()
    let bookmark = try service.makeTransferBookmark(for: original)
    try FileManager.default.moveItem(at: original, to: moved)

    #expect(throws: DirectoryAccessError.self) {
      try service.acquireDirectoryAccess(
        bookmark: bookmark,
        securityScoped: false,
        expectedIdentity: "different-identity"
      )
    }
  }

  /// Scenario: descriptor identity must match expected identity after path replacement.
  @Test func descriptorIdentityMustMatchExpectedIdentityAfterPathReplacement() {
    #expect(throws: DirectoryAccessError.self) {
      try validateDirectoryIdentity(
        openedIdentity: "replacement",
        currentPathIdentity: "replacement",
        expectedIdentity: "original"
      )
    }
  }

  /// Scenario: lease can be held across suspension.
  @Test func leaseCanBeHeldAcrossSuspension() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bookmark = try FileSystemService().makeTransferBookmark(for: directory)
    let lease = try FileSystemService().acquireDirectoryAccess(
      bookmark: bookmark, securityScoped: false)

    let names = await Task.detached {
      await Task.yield()
      return try? FileManager.default.contentsOfDirectory(atPath: lease.url.path)
    }.value

    #expect(names != nil)
  }
}

private func makeTemporaryDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("FileSystemAuthorization-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  return directory
}
