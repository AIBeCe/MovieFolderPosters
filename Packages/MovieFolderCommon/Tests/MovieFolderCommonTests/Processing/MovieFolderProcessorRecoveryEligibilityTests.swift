import FileSystem
import Foundation
import Network
import Persistence
import Testing

@testable import MovieFolderCommon

/// A changed retry timestamp cannot authorize repeating a stable blocked assessment.
@Test(arguments: [FolderProcessingReason.parsingProblem, .missingArtwork])
func automaticRecoveryKeepsBlockedReasonsUntilFolderEvidenceChanges(reason: FolderProcessingReason) async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Dune (2021)")
  let candidate = try #require(try FileSystemService().candidates(in: fixture.movies).first)
  let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
  try writeRecoveryCache(ProcessingState(folders: [candidate.name: FolderRecord(
    fingerprint: candidate.fingerprint, status: .unresolved,
    retryDate: clock.now.addingTimeInterval(-1), matchedMovieID: .none, posterPath: .none,
    processingReason: reason)]), fixture: fixture)
  let provider = CountingProvider()
  let processor = try fixture.processor(provider: provider, clock: { clock.now })

  let first = try await processor.process(root: fixture.movies)
  clock.advance(by: 172_800)
  let restarted = try fixture.processor(provider: provider, clock: { clock.now })
  let next = try await restarted.process(root: fixture.movies)

  #expect(first.examined == 0)
  #expect(next.examined == 0)
  #expect(first.unresolved == 1)
  #expect(await provider.searchCount == 0)
  #expect(fixture.assigner.assignmentCount == 0)
}

/// Incomplete cached searches cannot classify a newly eligible retry without fresh provider evidence.
@Test
func incompleteSearchRecoveryEvictsOnlyItsQueryBeforeRetry() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Dune (2021)")
  let candidate = try #require(try FileSystemService().candidates(in: fixture.movies).first)
  let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
  let queryKey = MovieFolderProcessor.queryKey(title: "Dune", year: 2021)
  let incomplete = CachedSearch(result: MovieSearchResult(movies: [], hasMorePages: true), createdAt: clock.now)
  try writeRecoveryCache(ProcessingState(folders: [candidate.name: FolderRecord(
    fingerprint: candidate.fingerprint, status: .unresolved,
    retryDate: clock.now.addingTimeInterval(-1), matchedMovieID: .none, posterPath: .none,
    processingReason: .incompleteSearch)], queries: [queryKey: incomplete, "unrelated": incomplete]), fixture: fixture)
  let provider = CountingProvider()
  let processor = try fixture.processor(provider: provider, clock: { clock.now })

  let result = try await processor.process(root: fixture.movies)

  #expect(result.assigned == 1)
  #expect(await provider.searchCount == 1)
  let saved = try readRecoveryCache(fixture)
  #expect(saved.queries["unrelated"] != nil)
  #expect(saved.folders[candidate.name]?.status == .processed)
}

/// A legacy unresolved decision bypasses both its obsolete delay and an inconclusive cached search once.
@Test
func legacyUnresolvedRecoveryReassessesFreshAndPersistsClassification() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Dune (2021)")
  let candidate = try #require(try FileSystemService().candidates(in: fixture.movies).first)
  let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
  let queryKey = MovieFolderProcessor.queryKey(title: "Dune", year: 2021)
  let incomplete = CachedSearch(result: MovieSearchResult(movies: [], hasMorePages: true), createdAt: clock.now)
  try writeRecoveryCache(ProcessingState(folders: [candidate.name: FolderRecord(
    fingerprint: candidate.fingerprint, status: .unresolved,
    retryDate: clock.now.addingTimeInterval(86_400), matchedMovieID: .none, posterPath: .none)],
    queries: [queryKey: incomplete, "unrelated": incomplete],
    rootBackoffUntil: clock.now.addingTimeInterval(86_400)), fixture: fixture)
  let provider = CountingProvider(search: MovieSearchResult(movies: [], hasMorePages: false))
  let processor = try fixture.processor(provider: provider, clock: { clock.now })

  let first = try await processor.process(root: fixture.movies)
  let restarted = try fixture.processor(provider: provider, clock: { clock.now })
  let next = try await restarted.process(root: fixture.movies)

  #expect(first.examined == 1)
  #expect(next.examined == 0)
  #expect(await provider.searchCount == 1)
  let saved = try readRecoveryCache(fixture)
  #expect(saved.folders[candidate.name]?.processingReason == .noSuitableMovie)
  #expect(saved.folders[candidate.name]?.retryDate == .none)
  #expect(saved.queries["unrelated"] != nil)
}

/// Provider failures retain distinct safe categories instead of becoming interchangeable unavailable errors.
@Test(arguments: [
  (TMDbError.transport(code: -1001), FolderProcessingReason.connectivity, FolderProcessingFailureReason.timeout),
  (.transport(code: -1009), .connectivity, .connectivity),
  (.httpStatus(503), .serverFailure, .serverFailure),
  (.malformedResponse, .invalidResponse, .invalidResponse),
  (.authentication, .authentication, .authentication)
])
func automaticRecoveryPersistsProviderFailureCategory(
  error: TMDbError, expectedReason: FolderProcessingReason, expectedFailure: FolderProcessingFailureReason
) async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Dune (2021)")
  let provider = CountingProvider(searchError: error)
  let processor = try fixture.processor(provider: provider)

  _ = try await processor.process(root: fixture.movies)

  let saved = try #require(try readRecoveryCache(fixture).folders["Dune (2021)"])
  #expect(saved.processingReason == expectedReason)
  #expect(saved.lastFailure?.reason == expectedFailure)
  if expectedReason == .authentication {
    #expect(saved.retryDate == nil)
  }
}

/// An interruption is durably classified before awaiting fresh legacy evidence, then resumes after restart.
@Test
func legacyReassessmentInterruptionPersistsResumeReason() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Dune (2021)")
  let candidate = try #require(try FileSystemService().candidates(in: fixture.movies).first)
  let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
  try writeRecoveryCache(ProcessingState(folders: [candidate.name: FolderRecord(
    fingerprint: candidate.fingerprint, status: .unresolved,
    retryDate: clock.now.addingTimeInterval(86_400), matchedMovieID: .none, posterPath: .none)]), fixture: fixture)
  let provider = CountingProvider(delaysSearch: true)
  let processor = try fixture.processor(provider: provider, clock: { clock.now })
  let task = Task { try await processor.process(root: fixture.movies) }
  await provider.waitForSearch()
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
  let interrupted = try readRecoveryCache(fixture)
  #expect(interrupted.folders[candidate.name]?.processingReason == .interrupted)
  #expect(interrupted.folders[candidate.name]?.retryDate == .none)

  let resumedProvider = CountingProvider(search: MovieSearchResult(movies: [], hasMorePages: false))
  let restarted = try fixture.processor(provider: resumedProvider, clock: { clock.now })
  let resumed = try await restarted.process(root: fixture.movies)
  #expect(resumed.unresolved == 1)
  #expect(await resumedProvider.searchCount == 1)
  #expect(try readRecoveryCache(fixture).folders[candidate.name]?.processingReason == .noSuitableMovie)
}

/// Nonfinite Retry-After text cannot corrupt the processor cache after shared policy safely handles the response.
@Test(arguments: ["nan", "inf", "-inf"])
func wrappedRateLimitRecoveryUsesFinitePersistedDeadline(header: String) async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Dune (2021)")
  let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
  let recovery = ProcessingRecoveryService(
    store: try PersistenceStore(directory: fixture.base.appendingPathComponent("Recovery")), now: { clock.now })
  let processor = MovieFolderProcessor(
    persistence: fixture.persistence,
    provider: RecoveryMovieMetadataProvider(
      provider: CountingProvider(searchError: .rateLimited(retryAfter: header)),
      recovery: recovery, credential: "token"),
    cacheDirectory: fixture.cache, now: { clock.now }, recovery: recovery)

  let summary = try await processor.process(root: fixture.movies)

  #expect(summary.rootBackoffUntil == clock.now.addingTimeInterval(600))
  let record = try #require(try readRecoveryCache(fixture).folders["Dune (2021)"])
  #expect(record.processingReason == .rateLimited)
  #expect(record.retryDate == summary.rootBackoffUntil)
  #expect(try recovery.read().providerRetryAt == summary.rootBackoffUntil)
}

/// Seeds the real operational store with historic evidence without touching movie contents.
private func writeRecoveryCache(_ state: ProcessingState, fixture: Fixture) throws {
  let lease = try #require(try fixture.persistence.acquireLease(
    for: MovieFolderProcessor.rootLeaseKey(for: fixture.movies)))
  try lease.write(JSONEncoder().encode(state))
}

/// Reads durable cache evidence after processing has released the root lease.
private func readRecoveryCache(_ fixture: Fixture) throws -> ProcessingState {
  let lease = try #require(try fixture.persistence.acquireLease(
    for: MovieFolderProcessor.rootLeaseKey(for: fixture.movies)))
  let bytes = try #require(try lease.read())

  return try JSONDecoder().decode(ProcessingState.self, from: bytes)
}
