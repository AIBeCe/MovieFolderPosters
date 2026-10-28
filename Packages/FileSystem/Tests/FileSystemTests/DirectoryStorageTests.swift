import Darwin
import Foundation
import Testing

@testable import FileSystem

struct DirectoryStorageTests {
  @Test func missingDoesNotCreateStorage() throws {
    let url = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    let usage = DirectoryStorage().measure(at: url)
    #expect(usage.status == .notCreated)
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test func countsRegularFilesAndRejectsLinks() throws {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(repeating: 1, count: 17).write(to: root.appendingPathComponent("regular"))
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("link").path,
      withDestinationPath: "/etc")
    let usage = DirectoryStorage().measure(at: root)
    #expect(usage.logicalBytes == 17)
    #expect(usage.fileCount == 1)
    #expect(usage.status == .partial)
  }

  @Test func finiteBoundMarksPartial() throws {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data([1]).write(to: root.appendingPathComponent("file"))
    #expect(DirectoryStorage(maximumEntries: 0).measure(at: root).status == .partial)
  }
  @Test func cancelledEmptyTraversalIsPartial() async throws {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let task = Task {
      while !Task.isCancelled { await Task.yield() }
      return DirectoryStorage().measure(at: root)
    }
    task.cancel()
    #expect(await task.value.status == .partial)
  }

  @Test func hardLinksAndSpecialEntriesAreOmitted() throws {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("regular")
    try Data([1, 2, 3]).write(to: file)
    try FileManager.default.linkItem(at: file, to: root.appendingPathComponent("hard-link"))
    #expect(mkfifo(root.appendingPathComponent("fifo").path, 0o600) == 0)
    let usage = DirectoryStorage().measure(at: root)
    #expect(usage.status == .partial)
    #expect(usage.fileCount == 0)
    #expect(usage.logicalBytes == 0)
  }

  @Test func rootLinksCannotRedirectMeasurement() throws {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    try FileManager.default.createSymbolicLink(atPath: root.path, withDestinationPath: "/etc")
    defer { try? FileManager.default.removeItem(at: root) }
    let usage = DirectoryStorage().measure(at: root)
    #expect(usage.status == .unavailable)
    #expect(usage.fileCount == 0)
  }

  @Test func nestedBoundsAndRegularNamespaceMarkerAreMeasuredConservatively() throws {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    let nested = root.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = nested.appendingPathComponent("marker")
    try Data([1, 2, 3]).write(to: marker)
    #expect(DirectoryStorage(maximumDepth: 0).measure(at: root).status == .partial)
    let usage = DirectoryStorage().measure(at: marker)
    #expect(usage.status == .complete)
    #expect(usage.logicalBytes == 3)
    #expect(usage.fileCount == 1)
    #expect(usage.finishedAt >= usage.startedAt)
  }

  @Test func readableTargetRemainsMeasurableThroughSearchOnlyAncestor() throws {
    let parent = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    let target = parent.appendingPathComponent("readable")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
      try? FileManager.default.removeItem(at: parent)
    }
    try Data([1, 2, 3]).write(to: target.appendingPathComponent("file"))
    try FileManager.default.setAttributes([.posixPermissions: 0o111], ofItemAtPath: parent.path)
    let usage = DirectoryStorage().measure(at: target)
    #expect(usage.status == .complete)
    #expect(usage.fileCount == 1)
    #expect(usage.logicalBytes == 3)
  }

}
