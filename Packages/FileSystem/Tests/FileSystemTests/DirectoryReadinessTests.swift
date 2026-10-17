import Darwin
import Foundation
import Testing

@testable import FileSystem

/// Exercises read-only readiness probes and their handling of missing, disconnected, and replaced paths.
struct DirectoryReadinessTests {
  /// Scenario: inspects existing directory without changing contents.
  @Test func inspectsExistingDirectoryWithoutChangingContents() throws {
    let directory = try makeReadinessDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let movie = directory.appendingPathComponent("Film.mkv")
    let movieContents = Data("movie contents must stay untouched".utf8)
    try movieContents.write(to: movie)
    let before = try FileManager.default.contentsOfDirectory(atPath: directory.path)

    let result = FileSystemService().inspectDirectory(at: directory)

    #expect(
      result.identity == (try? FileSystemService().persistentDirectoryIdentity(at: directory)))
    #expect(result.identity != nil || result.state == .unknown)
    #expect(result.volumePath != nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == before)
    #expect(try Data(contentsOf: movie) == movieContents)
  }

  /// Scenario: reports read only when directory lacks write permission.
  @Test(.enabled(if: geteuid() != 0, "permission checks require a non-root effective UID"))
  func reportsReadOnlyWhenDirectoryLacksWritePermission() throws {
    let directory = try makeReadinessDirectory()
    defer {
      _ = chmod(directory.path, mode_t(0o700))
      try? FileManager.default.removeItem(at: directory)
    }
    guard chmod(directory.path, mode_t(0o555)) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    #expect(FileSystemService().inspectDirectory(at: directory).state == .readOnly)
  }

  /// Scenario: reports access denied when directory cannot be read.
  @Test(.enabled(if: geteuid() != 0, "permission checks require a non-root effective UID"))
  func reportsAccessDeniedWhenDirectoryCannotBeRead() throws {
    let directory = try makeReadinessDirectory()
    defer {
      _ = chmod(directory.path, mode_t(0o700))
      try? FileManager.default.removeItem(at: directory)
    }
    guard chmod(directory.path, mode_t(0o000)) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    #expect(FileSystemService().inspectDirectory(at: directory).state == .accessDenied)
  }

  /// Scenario: distinguishes missing directory from wrong file type.
  @Test func distinguishesMissingDirectoryFromWrongFileType() throws {
    let root = try makeReadinessDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let missing = root.appendingPathComponent("Missing", isDirectory: true)
    let file = root.appendingPathComponent("movie.mkv")
    try Data().write(to: file)

    #expect(FileSystemService().inspectDirectory(at: missing).state == .missing)
    #expect(FileSystemService().inspectDirectory(at: file).state == .unsupported)
  }

  /// Scenario: reports disconnected only when recorded volume is not mounted.
  @Test func reportsDisconnectedOnlyWhenRecordedVolumeIsNotMounted() throws {
    let root = try makeReadinessDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let missing = root.appendingPathComponent("Missing", isDirectory: true)
    let absentVolume = root.appendingPathComponent("UnmountedVolume", isDirectory: true)

    #expect(
      FileSystemService().inspectDirectory(
        at: missing,
        expectedVolumePath: absentVolume.path
      ).state == .disconnected
    )
    #expect(FileSystemService().inspectDirectory(at: missing).state == .missing)
  }

  /// Scenario: rejects symbolic link as directory.
  @Test func rejectsSymbolicLinkAsDirectory() throws {
    let root = try makeReadinessDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("Movies", isDirectory: true)
    let link = root.appendingPathComponent("MoviesLink", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)

    #expect(FileSystemService().inspectDirectory(at: link).state == .unsupported)
  }

  /// Scenario: reports identity changed when directory was replaced.
  @Test func reportsIdentityChangedWhenDirectoryWasReplaced() throws {
    let root = try makeReadinessDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("Movies", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let expected = try #require(FileSystemService().inspectDirectory(at: directory).identity)
    try FileManager.default.removeItem(at: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

    let result = FileSystemService().inspectDirectory(at: directory, expectedIdentity: expected)
    #expect(result.state == .identityChanged)
  }
}

private func makeReadinessDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("FileSystemReadiness-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  return directory
}
