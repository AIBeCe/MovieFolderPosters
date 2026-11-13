import FileSystem
import Foundation
import Persistence
import Testing

@testable import Common

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
    #expect(event.matchingDiagnostics?.selectedTitle == "Dune")
    #expect(event.matchingDiagnostics?.selectedYear == 2021)
    #expect(event.matchingDiagnostics?.query?.year == .none)
    #expect(event.matchingDiagnostics?.search?.candidateCount == 0)
    #expect(event.matchingDiagnostics?.outcome == .noSuitableMatch)
    #expect(event.target?.movieID == .none)
    #expect(event.target?.movieTitle == .none)
  }

  /// A completed empty filename search retries the folder title and retains both queries in history.
  @Test func emptyVideoNameSearchRetriesFolderTitle() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let folder = "This.Is.Spinal.Tap.1984.BluRay.Remux.1080p.AVC.DTS-HD.MA.5.1-HiFi-AsRequested"
    try fixture.addFolder(folder)
    try Data().write(to: fixture.movies.appendingPathComponent(folder).appendingPathComponent("aWJl.mkv"))
    let movie = MovieMetadata(id: 11_031, title: "This Is Spinal Tap", originalTitle: "This Is Spinal Tap",
      releaseYear: 1984, posterPath: "/spinal-tap.jpg")
    let provider = CountingProvider(searchesByTitle: [
      "aWJl": MovieSearchResult(movies: [], hasMorePages: false),
      "This Is Spinal Tap": MovieSearchResult(movies: [movie], hasMorePages: false)
    ])
    let history = ProcessingActivityProbe()
    let processor = processor(fixture, provider: provider, history: history,
      movieMatchingConfiguration: MovieMatchingConfiguration(readsImmediateVideoNames: true))

    let summary = try await processor.process(root: fixture.movies)
    let event = try #require(await history.events.first)
    let diagnostics = try #require(event.matchingDiagnostics)

    #expect(summary.assigned == 1)
    #expect(await provider.searchQueries == ["aWJl", "This Is Spinal Tap"])
    #expect(event.folderResult == .posterApplied)
    #expect(event.target?.movieID == 11_031)
    #expect(diagnostics.selectedTitle == "This Is Spinal Tap")
    #expect(diagnostics.source == .conservativeMatch)
    #expect(diagnostics.previousAttempt?.selectedTitle == "aWJl")
    #expect(diagnostics.previousAttempt?.source == .videoNameInformation)
    #expect(diagnostics.previousAttempt?.search.candidateCount == 0)
    #expect(diagnostics.query?.title == "This Is Spinal Tap")
    #expect(diagnostics.search?.candidateCount == 1)
    #expect(diagnostics.text.contains("Earlier search title: aWJl"))
    #expect(diagnostics.text.contains("Search query: This Is Spinal Tap"))
  }

  /// An empty folder-name retry leaves a clear unresolved outcome with both attempted queries retained.
  @Test func emptyVideoAndFolderSearchesRemainNotFound() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let folder = "This.Is.Spinal.Tap.1984.BluRay"
    try fixture.addFolder(folder)
    try Data().write(to: fixture.movies.appendingPathComponent(folder).appendingPathComponent("aWJl.mkv"))
    let provider = CountingProvider(searchesByTitle: [
      "aWJl": MovieSearchResult(movies: [], hasMorePages: false),
      "This Is Spinal Tap": MovieSearchResult(movies: [], hasMorePages: false)
    ])
    let history = ProcessingActivityProbe()
    let processor = processor(fixture, provider: provider, history: history,
      movieMatchingConfiguration: MovieMatchingConfiguration(readsImmediateVideoNames: true))

    let summary = try await processor.process(root: fixture.movies)
    let event = try #require(await history.events.first)
    let diagnostics = try #require(event.matchingDiagnostics)

    #expect(summary.unresolved == 1)
    #expect(await provider.searchQueries == ["aWJl", "This Is Spinal Tap"])
    #expect(event.reason == .noSuitableMovie)
    #expect(diagnostics.previousAttempt?.search.candidateCount == 0)
    #expect(diagnostics.search?.candidateCount == 0)
    #expect(diagnostics.summary == "The selected title and folder-name fallback both returned no movies.")
  }

  /// An incomplete empty response cannot authorize a fallback search.
  @Test func incompleteVideoSearchDoesNotRetryFolderTitle() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let folder = "Dune.2021.BluRay"
    try fixture.addFolder(folder)
    try Data().write(to: fixture.movies.appendingPathComponent(folder).appendingPathComponent("Wrong.Movie.mkv"))
    let provider = CountingProvider(searchesByTitle: [
      "Wrong Movie": MovieSearchResult(movies: [], hasMorePages: true)
    ])
    let history = ProcessingActivityProbe()
    let processor = processor(fixture, provider: provider, history: history,
      movieMatchingConfiguration: MovieMatchingConfiguration(readsImmediateVideoNames: true))

    _ = try await processor.process(root: fixture.movies)

    #expect(await provider.searchQueries == ["Wrong Movie"])
    #expect(await history.events.first?.reason == .incompleteSearch)
    #expect(await history.events.first?.matchingDiagnostics?.previousAttempt == .none)
  }

  /// An empty cached filename result still advances to the folder title and retains its cache provenance.
  @Test func cachedEmptyVideoSearchStillRetriesFolderTitle() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let folders = ["Dune (2021)", "Dune.2021.1080p"]
    for folder in folders {
      try fixture.addFolder(folder)
      try Data().write(to: fixture.movies.appendingPathComponent(folder).appendingPathComponent("Wrong.Movie.mkv"))
    }
    let movie = MovieMetadata(id: 42, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
      posterPath: "/dune.jpg")
    let provider = CountingProvider(searchesByTitle: [
      "Wrong Movie": MovieSearchResult(movies: [], hasMorePages: false),
      "Dune": MovieSearchResult(movies: [movie], hasMorePages: false)
    ])
    let history = ProcessingActivityProbe()
    let processor = processor(fixture, provider: provider, history: history,
      movieMatchingConfiguration: MovieMatchingConfiguration(readsImmediateVideoNames: true))

    let summary = try await processor.process(root: fixture.movies)
    let events = await history.events
    let diagnostics = events.compactMap(\.matchingDiagnostics)

    #expect(summary.assigned == 2)
    #expect(await provider.searchQueries == ["Wrong Movie", "Dune"])
    #expect(diagnostics.count == 2)
    #expect(diagnostics.contains { $0.previousAttempt?.query.origin == .fresh })
    #expect(diagnostics.contains { $0.previousAttempt?.query.origin == .cached })
    #expect(diagnostics.contains { $0.query?.origin == .fresh })
    #expect(diagnostics.contains { $0.query?.origin == .cached })
  }

  /// Equivalent parsed titles do not trigger a duplicate folder-name provider query.
  @Test func identicalVideoAndFolderTitlesDoNotSearchTwice() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let folder = "Dune.2021.1080p"
    try fixture.addFolder(folder)
    try Data().write(to: fixture.movies.appendingPathComponent(folder).appendingPathComponent("Dune.2021.mkv"))
    let provider = CountingProvider(search: MovieSearchResult(movies: [], hasMorePages: false))
    let history = ProcessingActivityProbe()
    let processor = processor(fixture, provider: provider, history: history,
      movieMatchingConfiguration: MovieMatchingConfiguration(readsImmediateVideoNames: true))

    _ = try await processor.process(root: fixture.movies)

    #expect(await provider.searchQueries == ["Dune"])
    #expect(await history.events.first?.matchingDiagnostics?.previousAttempt == .none)
  }

  /// A nonempty unsuitable result is a real rejection and must not trigger a weaker folder query.
  @Test func unsuitableVideoCandidatesDoNotRetryFolderTitle() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let folder = "Dune.2021.BluRay"
    try fixture.addFolder(folder)
    try Data().write(to: fixture.movies.appendingPathComponent(folder).appendingPathComponent("Wrong.Movie.mkv"))
    let wrongMovie = MovieMetadata(id: 99, title: "Other Movie", originalTitle: "Other Movie",
      releaseYear: 2021, posterPath: "/other.jpg")
    let provider = CountingProvider(searchesByTitle: [
      "Wrong Movie": MovieSearchResult(movies: [wrongMovie], hasMorePages: false)
    ])
    let history = ProcessingActivityProbe()
    let processor = processor(fixture, provider: provider, history: history,
      movieMatchingConfiguration: MovieMatchingConfiguration(readsImmediateVideoNames: true))

    _ = try await processor.process(root: fixture.movies)

    #expect(await provider.searchQueries == ["Wrong Movie"])
    #expect(await history.events.first?.reason == .noSuitableMovie)
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
    await history.resetEvents()
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
    #expect(event.matchingDiagnostics?.query?.title == "Dune")
    #expect(event.matchingDiagnostics?.query?.origin == .fresh)
    #expect(event.matchingDiagnostics?.search == .none)
    #expect(event.target?.childFolderName == "Dune (2021)")
  }

  /// Manual artwork failure identifies the explicit selected movie and actual failed download stage.
  @Test func manualFailureRetainsSelectedMovie() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune (2021)")
    let history = ProcessingActivityProbe()
    let processor = processor(fixture, provider: CountingProvider(posterError: .malformedResponse), history: history)
    let candidate = try FileSystemService().readCurrentFolderCandidate(ofChild: "Dune (2021)", in: fixture.movies)
    let selectedMovie = MovieMetadata(id: 123, title: "Chosen Movie", originalTitle: "Chosen Movie",
      releaseYear: 2020, posterPath: "/chosen.jpg")
    await #expect(throws: MovieMetadataError.malformedResponse) {
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
    #expect(event.matchingDiagnostics == .none)
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
    let candidate = try FileSystemService().readCurrentFolderCandidate(ofChild: "Dune (2021)", in: fixture.movies)
    #expect(try await !processor.removePoster(
      root: fixture.movies, child: candidate.name, expectedIdentity: candidate.identity))
    #expect(await history.events.first?.folderResult == .noPosterToRemove)
  }

  /// Two fresh members reuse the actual cached query without inventing a provider-year restriction.
  @Test func cachedQueryDiagnosticsDescribeTheActualRequest() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune (2021)")
    try fixture.addFolder("Dune.2021.1080p")
    let history = ProcessingActivityProbe()
    let provider = CountingProvider()
    _ = try await processor(fixture, provider: provider, history: history).process(root: fixture.movies)
    let diagnostics = await history.events.compactMap(\.matchingDiagnostics)
    #expect(await provider.searchCount == 1)
    #expect(diagnostics.count == 2)
    #expect(diagnostics.filter { $0.query?.origin == .fresh }.count == 1)
    #expect(diagnostics.filter { $0.query?.origin == .cached }.count == 1)
    #expect(diagnostics.allSatisfy { $0.query?.year == .none && $0.selectedYear == 2021 })
    #expect(diagnostics.allSatisfy { $0.candidates.first?.verdict == .compatible })
    #expect(diagnostics.allSatisfy { $0.finalResult == .posterApplied })
  }

  /// Candidate mismatches and a missing poster explain the actual terminal blocker independently.
  @Test func actualCandidateChecksDoNotClaimPosterSuccess() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune (2021)")
    let matching = MovieMetadata(id: 42, title: "Dune", originalTitle: "Dune", releaseYear: 2021, posterPath: .none)
    let wrongTitle = MovieMetadata(id: 43, title: "Alien", originalTitle: "Alien", releaseYear: 2021,
      posterPath: "/alien.jpg")
    let wrongYear = MovieMetadata(id: 44, title: "Dune", originalTitle: "Dune", releaseYear: 1984,
      posterPath: "/old.jpg")
    let history = ProcessingActivityProbe()
    let provider = CountingProvider(search: .init(movies: [matching, wrongTitle, wrongYear], hasMorePages: false))
    _ = try await processor(fixture, provider: provider, history: history).process(root: fixture.movies)
    let diagnostics = try #require(await history.events.first?.matchingDiagnostics)
    #expect(diagnostics.candidates.map(\.verdict) == [.compatible, .titleMismatch, .outsideYearWindow])
    #expect(diagnostics.outcome == .matched)
    #expect(diagnostics.finalReason == .missingArtwork)
    #expect(diagnostics.summary.contains(FolderProcessingReason.missingArtwork.userDescription))
    #expect(await provider.posterCount == 0)
  }

  /// A rejected year prerequisite differs from a completed empty search.
  @Test func missingRequiredYearDoesNotInventASearch() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune")
    let history = ProcessingActivityProbe()
    let provider = CountingProvider()
    let directory = MonitoredDirectory(id: UUID(), path: fixture.movies.path, transferBookmark: Data(),
      authorizationVersion: UUID())
    let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
      cacheDirectory: fixture.cache,
      movieMatchingConfiguration: .init(requiresReleaseYearForAutomaticMatching: true),
      activityHistoryService: history, activityLogContext: .init(directory: directory))
    _ = try await processor.process(root: fixture.movies)
    let diagnostics = try #require(await history.events.first?.matchingDiagnostics)
    #expect(diagnostics.selectedTitle == "Dune")
    #expect(diagnostics.query == .none)
    #expect(diagnostics.search == .none)
    #expect(diagnostics.outcome == .notEvaluated)
    #expect(await provider.searchCount == 0)
  }

  /// A primary year within the lookup window still needs dated release evidence for the selected year.
  @Test func releaseYearMismatchExplainsWhyCandidateWasRejected() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune (2021)")
    let history = ProcessingActivityProbe()
    let provider = CountingProvider(primaryReleaseYear: 2020)
    _ = try await processor(fixture, provider: provider, history: history).process(root: fixture.movies)
    let diagnostics = try #require(await history.events.first?.matchingDiagnostics)
    #expect(diagnostics.selectedYear == 2021)
    #expect(diagnostics.candidates.first?.year == 2020)
    #expect(diagnostics.candidates.first?.verdict == .yearMismatch)
    #expect(diagnostics.outcome == .noSuitableMatch)
    #expect(diagnostics.summary.contains("selected release year 2021"))
    #expect(await provider.posterCount == 0)
  }

  /// A failed first search records its attempted inputs without inventing an empty response.
  @Test func providerFailureRetainsAttemptedInputs() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune (2021)")
    let history = ProcessingActivityProbe()
    let provider = CountingProvider(searchError: .authentication)
    _ = try await processor(fixture, provider: provider, history: history).process(root: fixture.movies)
    let diagnostics = try #require(await history.events.first?.matchingDiagnostics)
    #expect(diagnostics.query?.title == "Dune")
    #expect(diagnostics.query?.year == .none)
    #expect(diagnostics.query?.origin == .fresh)
    #expect(diagnostics.search == .none)
    #expect(diagnostics.candidates.isEmpty)
    #expect(diagnostics.finalReason == .authentication)
    #expect(diagnostics.outcome == .notEvaluated)
  }

  /// Identifier matching does not fabricate title-search inputs or normalized title checks.
  @Test func identifierDiagnosticsDescribeOnlyTheActualResolution() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Movie [imdb:tt0078748]")
    let movie = MovieMetadata(id: 348, title: "Alien", originalTitle: "Alien", releaseYear: 1979,
      posterPath: "/alien.jpg")
    let history = ProcessingActivityProbe()
    let provider = CountingProvider(imdbMovies: ["tt0078748": movie])
    _ = try await processor(fixture, provider: provider, history: history).process(root: fixture.movies)
    let diagnostics = try #require(await history.events.first?.matchingDiagnostics)
    #expect(diagnostics.source == .validatedIdentifier)
    #expect(diagnostics.selectedTitle == .none)
    #expect(diagnostics.query == .none)
    #expect(diagnostics.search == .none)
    #expect(diagnostics.outcome == .identifierMatched)
    #expect(diagnostics.candidates.first?.verdict == .identifierResolved)
    #expect(!diagnostics.text.contains("tt0078748"))
    #expect(await provider.searchCount == 0)
  }

  /// Builds a processor using real isolated filesystem effects and a retained event probe.
  private func processor(
    _ fixture: Fixture, provider: CountingProvider = CountingProvider(), history: ProcessingActivityProbe,
    movieMatchingConfiguration: MovieMatchingConfiguration = MovieMatchingConfiguration()
  ) -> MovieFolderProcessor {
    let directory = MonitoredDirectory(
      id: UUID(), path: fixture.movies.path, transferBookmark: Data(), authorizationVersion: UUID())

    return MovieFolderProcessor(
      persistence: fixture.persistence, provider: provider, cacheDirectory: fixture.cache,
      movieMatchingConfiguration: movieMatchingConfiguration, activityHistoryService: history,
      activityLogContext: MovieFolderActivityLogContext(directory: directory))
  }
}

/// Isolated retained events let tests inspect actual terminal facts without configuring global history.
actor ProcessingActivityProbe: MovieFolderActivityRecording {
  /// Events accepted during this test only.
  private(set) var events: [MovieFolderActivityLogEvent] = []

  /// Clears only the probe's in-memory assertions between phases of a test.
  func resetEvents() { events.removeAll() }
  /// Whether this probe accepts a history write.
  private let acceptsWrites: Bool
  /// An optional processing store whose lease must have been released before recording.
  private let checkingStore: PersistenceStore?
  /// The exact operational key tested at the report boundary.
  private let checkingKey: String?

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
}
