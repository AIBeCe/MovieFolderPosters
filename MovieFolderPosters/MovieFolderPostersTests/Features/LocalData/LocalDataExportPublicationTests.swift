import Foundation
import MovieFolderCommon
import Testing

@testable import MovieFolderPosters

/// Holds actual temporary staging before the publication owner regains control.
actor LocalDataExportTemporaryFileWriterFake: LocalDataExportTemporaryFileWriting {
  /// Real stage writer ensures regressions exercise destination and temporary-file effects.
  private let writer = SystemLocalDataExportTemporaryFileWriter()
  /// Whether staging waits until the test explicitly releases it.
  private let holdsStage: Bool
  /// Suspended stage result, intentionally ignoring cancellation to exercise the owner's final fence.
  private var continuation: CheckedContinuation<Void, Never>?
  /// Staged location used to verify cleanup after cancellation and success.
  private(set) var stagedDirectory: URL?
  /// Whether staging failed before reaching the controlled suspension.
  private(set) var stageFailed = false
  /// Whether stage bytes exist and publication is currently held.
  var isHeld: Bool { continuation != nil }

  /// Configures deterministic staging suspension.
  init(holdsStage: Bool) { self.holdsStage = holdsStage }
  /// Releases a staged result after the owner has closed or changed evidence.
  func release() {
    continuation?.resume()
    continuation = nil
  }

  func stage(bytes: Data, destination: URL) async throws -> PreparedLocalDataExportFile {
    let staged: PreparedLocalDataExportFile
    do { staged = try await writer.stage(bytes: bytes, destination: destination) } catch {
      stageFailed = true
      throw error
    }
    stagedDirectory = staged.directory
    if holdsStage { await withCheckedContinuation { continuation = $0 } }

    return staged
  }
}

@MainActor
struct LocalDataExportPublicationTests {
  /// Creates one prepared empty-selection session independent of production storage.
  private func preparedModel() async throws -> (LocalDataExportViewModel, LocalDataExportSourcesFake) {
    let source = LocalDataExportSourcesFake(.init(activity: [], network: [], privacy: Data([1])))
    let model = LocalDataExportViewModel(service: source, readiness: nil)
    await model.reload()
    model.selection.includesStorage = false
    try await model.preparePreview()

    return (model, source)
  }

  @Test(arguments: [false, true], [false, true])
  func cancellationBeforePublicationPreservesDestinationAndRemovesStage(
    replacesExisting: Bool, cancelsTask: Bool
  ) async throws {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("support.json")
    let existing = Data("Existing destination".utf8)
    if replacesExisting { try existing.write(to: destination) }
    let (model, _) = try await preparedModel()
    let stager = LocalDataExportTemporaryFileWriterFake(holdsStage: true)
    let operation = LocalDataExportWriter(model: model, staging: stager)
    let saving = Task { try await operation.save(to: destination) }
    while !(await stager.isHeld), !(await stager.stageFailed) { await Task.yield() }
    try #require(await stager.isHeld)
    let stagedDirectory = try #require(await stager.stagedDirectory)
    #expect(FileManager.default.fileExists(atPath: stagedDirectory.path))
    if cancelsTask { saving.cancel() } else { operation.close() }
    await stager.release()
    await #expect(throws: LocalDataExportError.self) { try await saving.value }
    if replacesExisting {
      #expect(try Data(contentsOf: destination) == existing)
    } else {
      #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
    #expect(!FileManager.default.fileExists(atPath: stagedDirectory.path))
  }

  @Test func successfulPublicationWritesExactlyReviewedBytesAndRemovesStage() async throws {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("support.json")
    try Data("Old file".utf8).write(to: destination)
    let (model, _) = try await preparedModel()
    let frozen = try #require(model.preview)
    let stager = LocalDataExportTemporaryFileWriterFake(holdsStage: false)
    let operation = LocalDataExportWriter(model: model, staging: stager)
    try await operation.save(to: destination)
    #expect(try Data(contentsOf: destination) == frozen)
    let stagedDirectory = try #require(await stager.stagedDirectory)
    #expect(!FileManager.default.fileExists(atPath: stagedDirectory.path))
  }

  @Test func changedPrivacyDuringStageRejectsPublication() async throws {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("support.json")
    let (model, source) = try await preparedModel()
    let stager = LocalDataExportTemporaryFileWriterFake(holdsStage: true)
    let operation = LocalDataExportWriter(model: model, staging: stager)
    let saving = Task { try await operation.save(to: destination) }
    while !(await stager.isHeld), !(await stager.stageFailed) { await Task.yield() }
    try #require(await stager.isHeld)
    await source.replace(.init(activity: [], network: [], privacy: Data([2])))
    await stager.release()
    await #expect(throws: LocalDataExportError.self) { try await saving.value }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    let stagedDirectory = try #require(await stager.stagedDirectory)
    #expect(!FileManager.default.fileExists(atPath: stagedDirectory.path))
  }
  @Test func failedPublicationPreservesDestinationAndRemovesStage() async throws {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    let destination = root.appendingPathComponent("changed-to-directory")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sentinel = destination.appendingPathComponent("sentinel")
    let existing = Data("Existing directory contents".utf8)
    try existing.write(to: sentinel)
    let (model, _) = try await preparedModel()
    let stager = LocalDataExportTemporaryFileWriterFake(holdsStage: false)
    let operation = LocalDataExportWriter(model: model, staging: stager)
    await #expect(throws: LocalDataExportError.self) { try await operation.save(to: destination) }
    #expect(try Data(contentsOf: sentinel) == existing)
    let stagedDirectory = try #require(await stager.stagedDirectory)
    #expect(!FileManager.default.fileExists(atPath: stagedDirectory.path))
  }

}
