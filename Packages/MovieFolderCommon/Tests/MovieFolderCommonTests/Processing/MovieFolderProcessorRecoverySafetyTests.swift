import FileSystem
import Foundation
import Network
import Persistence
import Testing

@testable import MovieFolderCommon

/// Existing processor instances must recheck durable recovery mode before every automatic invocation.
@Test
func recoveryModeBlocksCachedAutomaticProcessorBeforeAnyProviderRequest() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Dune (2021)")
  let recovery = ProcessingRecoveryService(
    store: try PersistenceStore(directory: fixture.base.appendingPathComponent("Recovery")))
  let provider = CountingProvider()
  let processor = MovieFolderProcessor(
    persistence: fixture.persistence, provider: provider, cacheDirectory: fixture.cache,
    posterAssigner: fixture.assigner, recovery: recovery)
  try recovery.setRecoveryModeEnabled(true)

  await #expect(throws: ProcessingRecoveryError.recoveryMode) { try await processor.process(root: fixture.movies) }

  #expect(await provider.searchCount == 0)
  #expect(fixture.assigner.assignmentCount == 0)
}

/// A response admitted before recovery mode was enabled cannot authorize the subsequent poster write.
@Test
func recoveryModeEnabledDuringSearchPreventsAutomaticAssignment() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Dune (2021)")
  let recovery = ProcessingRecoveryService(
    store: try PersistenceStore(directory: fixture.base.appendingPathComponent("Recovery")))
  let provider = CountingProvider(delaysSearch: true)
  let processor = MovieFolderProcessor(
    persistence: fixture.persistence, provider: provider, cacheDirectory: fixture.cache,
    posterAssigner: fixture.assigner, recovery: recovery)
  let task = Task { try await processor.process(root: fixture.movies) }
  await provider.waitForSearch()
  try recovery.setRecoveryModeEnabled(true)
  await provider.allowSearch()

  await #expect(throws: ProcessingRecoveryError.recoveryMode) { try await task.value }
  #expect(fixture.assigner.assignmentCount == 0)
}

/// All explicit mutations check recovery mode, including removal without a provider request.
@Test(arguments: ["refresh", "selection", "removal"])
func recoveryModeBlocksEveryManualChange(action: String) async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Dune (2021)")
  let candidate = try #require(try FileSystemService().candidates(in: fixture.movies).first)
  let recovery = ProcessingRecoveryService(
    store: try PersistenceStore(directory: fixture.base.appendingPathComponent("Recovery")))
  let provider = CountingProvider()
  let processor = MovieFolderProcessor(
    persistence: fixture.persistence, provider: provider, cacheDirectory: fixture.cache, recovery: recovery)
  try recovery.setRecoveryModeEnabled(true)

  await #expect(throws: ProcessingRecoveryError.recoveryMode) {
    switch action {
    case "refresh":
      _ = try await processor.refreshPoster(root: fixture.movies, child: candidate.name,
        expectedIdentity: candidate.identity)
    case "selection":
      let movie = MovieMetadata(id: 42, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
        posterPath: "/dune.jpg")
      _ = try await processor.applyMoviePoster(movie, root: fixture.movies, child: candidate.name,
        expectedIdentity: candidate.identity)
    default:
      _ = try await processor.removePoster(root: fixture.movies, child: candidate.name,
        expectedIdentity: candidate.identity)
    }
  }
  #expect(await provider.searchCount == 0)
  #expect(await provider.posterCount == 0)
}

/// Recovery activation and a synchronous automatic icon write use the same cross-instance access.
@Test
func recoveryChangeAccessCoversAutomaticAssignment() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Dune (2021)")
  let recovery = ProcessingRecoveryService(
    store: try PersistenceStore(directory: fixture.base.appendingPathComponent("Recovery")))
  let processor = MovieFolderProcessor(
    persistence: fixture.persistence, provider: CountingProvider(), cacheDirectory: fixture.cache,
    posterAssigner: RecoveryAccessAssertingAssigner(recovery: recovery), recovery: recovery)

  let summary = try await processor.process(root: fixture.movies)

  #expect(summary.assigned == 1)
  #expect(try !recovery.read().isRecoveryModeEnabled)
}

/// Tests the real recovery access at the icon adapter boundary without modifying fixture movie metadata.
private struct RecoveryAccessAssertingAssigner: PosterAssigner {
  /// The independent shared service attempting activation during the synchronous change.
  let recovery: ProcessingRecoveryService

  func assignPoster(
    _ imageData: Data, toChild name: String, in directory: URL, expectedIdentity: String?
  ) throws -> PosterAssignmentResult {
    #expect(throws: ProcessingRecoveryError.busy) { try recovery.setRecoveryModeEnabled(true) }

    return .assigned
  }
}
