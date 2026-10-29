import FileSystem
import Foundation
import Network
import Persistence
import Testing

@testable import MovieFolderCommon

/// Rejected credentials do not repeat requests, while changed credentials can recover the same saved folder.
@Test
func automaticRecoveryAcceptsChangedCredentialWithoutObsoleteFolderDelay() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Dune (2021)")
  let recovery = ProcessingRecoveryService(
    store: try PersistenceStore(directory: fixture.base.appendingPathComponent("Recovery")))
  let rejected = CountingProvider(searchError: .authentication)
  let oldProvider = RecoveryMovieMetadataProvider(provider: rejected, recovery: recovery, credential: "old")
  let initial = MovieFolderProcessor(
    persistence: fixture.persistence, provider: oldProvider, cacheDirectory: fixture.cache,
    posterAssigner: fixture.assigner, recovery: recovery)
  _ = try await initial.process(root: fixture.movies)
  _ = try await initial.process(root: fixture.movies)
  #expect(await rejected.searchCount == 1)
  let accepted = CountingProvider()
  let replacement = MovieFolderProcessor(
    persistence: fixture.persistence,
    provider: RecoveryMovieMetadataProvider(provider: accepted, recovery: recovery, credential: "new"),
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner, recovery: recovery)

  let result = try await replacement.process(root: fixture.movies)

  #expect(result.assigned == 1)
  #expect(await accepted.searchCount == 1)
}

/// A temporary failure remains delayed until a later invocation, then recovers with a fresh provider request.
@Test(arguments: [TMDbError.transport(code: NSURLErrorNotConnectedToInternet), .httpStatus(503)])
func automaticTemporaryRecoveryRequiresLaterEligibleInvocation(error: TMDbError) async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Dune (2021)")
  let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
  let recovery = ProcessingRecoveryService(
    store: try PersistenceStore(directory: fixture.base.appendingPathComponent("Recovery")), now: { clock.now })
  let initial = MovieFolderProcessor(
    persistence: fixture.persistence,
    provider: RecoveryMovieMetadataProvider(
      provider: CountingProvider(searchError: error), recovery: recovery, credential: "token"),
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner, now: { clock.now }, recovery: recovery)
  _ = try await initial.process(root: fixture.movies)
  let accepted = CountingProvider()
  let resumed = MovieFolderProcessor(
    persistence: fixture.persistence,
    provider: RecoveryMovieMetadataProvider(provider: accepted, recovery: recovery, credential: "token"),
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner, now: { clock.now }, recovery: recovery)
  clock.advance(by: 100)
  let waiting = try await resumed.process(root: fixture.movies)
  #expect(waiting.skippedRetryWindow == 1)
  #expect(await accepted.searchCount == .zero)
  clock.advance(by: 600)

  let recovered = try await resumed.process(root: fixture.movies)

  #expect(recovered.assigned == 1)
  #expect(await accepted.searchCount == 1)
}

/// Restarting after a checkpoint preserves a real owned icon and resumes only the unfinished member.
@Test
func interruptedRecoveryPreservesVerifiedWriteAcrossProcessorRestart() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Alpha (2021)")
  try fixture.addFolder("Beta (2021)")
  let pending = CountingProvider(delaysSearch: true)
  let provider = RecoveryCheckpointProvider(pending: pending)
  let initial = MovieFolderProcessor(
    persistence: fixture.persistence, provider: provider, cacheDirectory: fixture.cache)
  let task = Task { try await initial.process(root: fixture.movies) }
  await pending.waitForSearch()
  #expect(try FileSystemService().hasAssignedPoster(toChild: "Alpha (2021)", in: fixture.movies))
  let icon = fixture.movies.appendingPathComponent("Alpha (2021)/Icon\r")
  let originalIconDate = try icon.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
  let resumedProvider = CountingProvider()
  let restarted = MovieFolderProcessor(
    persistence: fixture.persistence, provider: resumedProvider, cacheDirectory: fixture.cache)

  let resumed = try await restarted.process(root: fixture.movies)

  #expect(resumed.assigned == 1)
  #expect(await resumedProvider.searchCount == 1)
  #expect(await resumedProvider.posterCount == .zero)
  #expect(try FileSystemService().hasAssignedPoster(toChild: "Beta (2021)", in: fixture.movies))
  #expect(try icon.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == originalIconDate)
}

/// Allows the first real icon checkpoint and exposes a cancellable provider boundary for the second member.
private struct RecoveryCheckpointProvider: MovieMetadataProvider {
  /// Provider whose continuation establishes the unfinished-member checkpoint.
  let pending: CountingProvider
  /// Normal deterministic metadata and valid source artwork for the first member.
  let completed = CountingProvider()

  /// Supplies completed empty alternative-title evidence for this focused fixture.
  func alternativeTitles(movieID: Int) async throws -> MovieAlternativeTitles { [movieID: []] }

  func searchMovies(title: String, year: Int?, language: TMDbLanguage = .english) async throws -> MovieSearchResult {
    try await (title == "Beta" ? pending : completed).searchMovies(title: title, year: year)
  }

  func downloadPoster(path: String) async throws -> Data { try await completed.downloadPoster(path: path) }
}
