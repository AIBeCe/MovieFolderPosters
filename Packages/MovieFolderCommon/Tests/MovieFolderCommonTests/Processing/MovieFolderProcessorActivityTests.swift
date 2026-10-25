import FileSystem
import Foundation
import Network
import Persistence
import Testing

@testable import MovieFolderCommon

/// Actual operation reporting remains independent of durable latest-folder assessments.
struct MovieFolderProcessorActivityTests {
  /// A real assignment reports its confirmed movie; an unchanged owned icon emits no applied event.
  @Test func appliedAndUnchangedAreDistinct() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune (2021)")
    let history = ProcessingActivityProbe(
      checkingStore: fixture.persistence, checkingKey: MovieFolderProcessor.processingStateKey(for: fixture.movies))
    let processor = processor(fixture, history: history)
    _ = try await processor.process(root: fixture.movies)
    let first = await history.events
    #expect(first.filter { $0.folderResult == .posterApplied }.count == 1)
    #expect(first.first?.target?.childFolderName == "Dune (2021)")
    #expect(first.first?.target?.movieID == 42)
    let firstCount = first.count
    _ = try await processor.process(root: fixture.movies)
    #expect(await history.events.count == firstCount)
  }

  /// A conclusive negative result records no invented movie identity or search title.
  @Test func negativeMatchingRetainsActualClassification() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune (2021)")
    let history = ProcessingActivityProbe()
    let provider = CountingProvider(search: MovieSearchResult(movies: [], hasMorePages: false))
    let processor = processor(fixture, provider: provider, history: history)
    _ = try await processor.process(root: fixture.movies)
    let event = try #require(await history.events.first)
    #expect(event.folderResult == .notFound)
    #expect(event.reason == .noSuitableMovie)
    #expect(event.target?.movieID == .none)
    #expect(event.target?.movieTitle == .none)
  }

  /// Parsing, ambiguity and incomplete search remain distinct from a conclusive no-match result.
  @Test(arguments: [FolderProcessingReason.parsingProblem, .ambiguousMovie, .incompleteSearch])
  func unresolvedReasonsRemainDistinct(_ reason: FolderProcessingReason) async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder(reason == .parsingProblem ? "Dune (2021) [unknown-12345]" : "Dune (2021)")
    let movie = MovieMetadata(id: 42, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
      posterPath: "/dune.jpg")
    let otherMovie = MovieMetadata(id: 43, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
      posterPath: "/other.jpg")
    let search = MovieSearchResult(movies: [movie, otherMovie], hasMorePages: reason == .incompleteSearch)
    let history = ProcessingActivityProbe()
    let processor = processor(fixture, provider: CountingProvider(search: search), history: history)
    _ = try await processor.process(root: fixture.movies)
    let event = try #require(await history.events.first)
    #expect(event.reason == reason)
    #expect(event.folderResult == (reason == .ambiguousMovie ? .severalMatches : .unresolved))
    #expect(event.target?.movieID == .none)
    #expect(event.target?.movieTitle == .none)
  }

  /// Repairing only cached artwork preserves the installed icon and never claims another assignment.
  @Test func sourceArtworkRepairDoesNotClaimPosterApplication() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune (2021)")
    let history = ProcessingActivityProbe()
    let processor = processor(fixture, history: history)
    _ = try await processor.process(root: fixture.movies)
    await history.clear()
    let cachedPoster = fixture.cache.appendingPathComponent(MovieFolderProcessor.posterCacheName("/dune.jpg"))
    try Data("invalid poster".utf8).write(to: cachedPoster)
    _ = try await processor.process(root: fixture.movies)
    let events = await history.events
    #expect(events.map(\.folderResult) == [.preserved])
    #expect(events.first?.target?.movieID == 42)
  }

  /// A rejected optional history write cannot change the successful processing result.
  @Test func reportingFailurePreservesProductResult() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune (2021)")
    let history = ProcessingActivityProbe(acceptsWrites: false)
    let processor = processor(fixture, history: history)
    let summary = try await processor.process(root: fixture.movies)
    #expect(summary.assigned == 1)
    #expect(await history.events.first?.folderResult == .posterApplied)
  }

  /// An artwork failure retains the confirmed movie, typed stage and retry eligibility.
  @Test func artworkFailureRetainsAttemptEvidence() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune (2021)")
    let history = ProcessingActivityProbe()
    let provider = CountingProvider(posterError: .malformedResponse)
    let processor = processor(fixture, provider: provider, history: history)
    _ = try await processor.process(root: fixture.movies)
    let event = try #require(await history.events.first)
    #expect(event.folderResult == .failed)
    #expect(event.target?.movieID == 42)
    #expect(event.failure?.stage == .artwork)
    #expect(event.failure?.reason == .invalidResponse)
    #expect(event.retryAt != .none)
  }

  /// A cancellation while searching cannot become a poster-success record.
  @Test func cancellationReportsTheActiveFolder() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune (2021)")
    let history = ProcessingActivityProbe()
    let provider = CountingProvider(delaysSearch: true)
    let processor = processor(fixture, provider: provider, history: history)
    let task = Task { try await processor.process(root: fixture.movies) }
    await provider.waitForSearch()
    task.cancel()
    _ = await task.result
    let event = try #require(await history.events.first)
    #expect(event.folderResult == .cancelled)
    #expect(event.failure?.stage == .search)
    #expect(event.target?.childFolderName == "Dune (2021)")
  }

  /// Manual artwork failure identifies the explicit selected movie and actual failed download stage.
  @Test func manualFailureRetainsSelectedMovie() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune (2021)")
    let history = ProcessingActivityProbe()
    let processor = processor(fixture, provider: CountingProvider(posterError: .malformedResponse), history: history)
    let candidate = try FileSystemService().readCurrentState(ofChild: "Dune (2021)", in: fixture.movies)
    let selectedMovie = MovieMetadata(id: 123, title: "Chosen Movie", originalTitle: "Chosen Movie",
      releaseYear: 2020, posterPath: "/chosen.jpg")
    await #expect(throws: TMDbError.malformedResponse) {
      try await processor.applyMoviePoster(selectedMovie, root: fixture.movies, child: candidate.name,
        expectedIdentity: candidate.identity)
    }
    let event = try #require(await history.events.first)
    #expect(event.action == .posterSelection)
    #expect(event.folderResult == .failed)
    #expect(event.target?.movieID == 123)
    #expect(event.target?.movieTitle == "Chosen Movie")
    #expect(event.failure?.stage == .artwork)
    #expect(event.failure?.reason == .invalidResponse)
  }

  /// A fresh per-visit context captures the current privacy choice without mutating the processor's composition.
  @Test func invocationContextPreservesCapturePrivacy() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune (2021)")
    let history = ProcessingActivityProbe()
    let processor = processor(fixture, history: history)
    let privateDirectory = MonitoredDirectory(id: UUID(), path: fixture.movies.path,
      transferBookmark: Data(), authorizationVersion: UUID(), usesPrivateHistory: true)
    _ = try await processor.process(root: fixture.movies,
      activityLogContext: MovieFolderActivityLogContext(directory: privateDirectory))
    let event = try #require(await history.events.first)
    #expect(event.folderResult == .posterApplied)
    #expect(event.collectionID == .none)
    #expect(event.activityGroupID == .none)
    #expect(event.target == .none)
    try fixture.addFolder("Arrival (2016)")
    _ = try await processor.process(root: fixture.movies)
    #expect(await history.events.last?.target?.childFolderName == "Arrival (2016)")
  }

  /// A no-op removal has its own result instead of claiming an actual removal.
  @Test func removalWithoutPosterReportsNoPoster() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune (2021)")
    let history = ProcessingActivityProbe()
    let processor = processor(fixture, history: history)
    let candidate = try FileSystemService().readCurrentState(ofChild: "Dune (2021)", in: fixture.movies)
    #expect(try await !processor.removePoster(
      root: fixture.movies, child: candidate.name, expectedIdentity: candidate.identity))
    #expect(await history.events.first?.folderResult == .noPosterToRemove)
  }

  /// Builds a processor using real isolated filesystem effects and a retained event probe.
  private func processor(
    _ fixture: Fixture, provider: CountingProvider = CountingProvider(), history: ProcessingActivityProbe
  ) -> MovieFolderProcessor {
    let directory = MonitoredDirectory(
      id: UUID(), path: fixture.movies.path, transferBookmark: Data(), authorizationVersion: UUID())

    return MovieFolderProcessor(
      persistence: fixture.persistence, provider: provider, cacheDirectory: fixture.cache,
      activityHistoryService: history, activityLogContext: MovieFolderActivityLogContext(directory: directory))
  }
}

/// Isolated retained events let tests inspect actual terminal facts without configuring global history.
actor ProcessingActivityProbe: MovieFolderActivityServicing {
  /// Events accepted during this test only.
  private(set) var events: [MovieFolderActivityLogEvent] = []
  /// Whether this probe accepts a history write.
  private let acceptsWrites: Bool
  /// An optional processing store whose lease must have been released before recording.
  private let checkingStore: PersistenceStore?
  /// The exact operational key tested at the report boundary.
  private let checkingKey: String?
  /// Whether the probe has intentionally rejected writes.
  var hasObservedWriteFailure: Bool { !acceptsWrites }

  /// Configures optional write rejection and root-lock lifetime assertions.
  init(acceptsWrites: Bool = true, checkingStore: PersistenceStore? = .none, checkingKey: String? = .none) {
    self.acceptsWrites = acceptsWrites
    self.checkingStore = checkingStore
    self.checkingKey = checkingKey
  }

  func record(_ event: MovieFolderActivityLogEvent) -> Bool {
    if let checkingStore, let checkingKey {
      let access = try? checkingStore.acquireAccess(for: checkingKey)
      if let access {
        withExtendedLifetime(access) {}
      } else {
        Issue.record("The processing lease remained held while activity was recorded.")
      }
    }
    events.append(event)

    return acceptsWrites
  }

  func entries() -> [MovieFolderActivityLogEntry] { [] }
  func clear() { events.removeAll() }
}
