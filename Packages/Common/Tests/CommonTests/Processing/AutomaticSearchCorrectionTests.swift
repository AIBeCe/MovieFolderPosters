import FileSystem
import Foundation
@testable import Common
import Persistence
import Testing

/// Covers correction input and freshness through the real automatic processor and persistence.
struct AutomaticSearchCorrectionTests {
  /// A new correction reopens an inconclusive assessment and establishes its own provenance.
  @Test func savedCorrectionReopensUnresolvedFolder() async throws {
    let scenario = try CorrectionScenario()
    defer { scenario.cleanup() }
    let initial = scenario.processor(provider: CountingProvider(search: .init(movies: [], hasMorePages: false)))
    let first = try await initial.process(root: scenario.fixture.movies, processingContext: scenario.context)
    #expect(first.unresolved == 1)
    let correction = try FolderSearchCorrection(title: "Dune", year: 2021)
    try scenario.save(correction)

    let provider = CountingProvider()
    let processor = scenario.processor(provider: provider)
    let corrected = try await processor.process(root: scenario.fixture.movies, processingContext: scenario.context)
    #expect(corrected.assigned == 1)
    #expect(await provider.searchCount == 1)
    #expect(try scenario.record()?.movieIdentitySource == .savedSearchCorrection)
  }

  /// Identifier disagreement blocks assignment even after the corrected title matches.
  @Test(arguments: [true, false])
  func correctedSearchMustAgreeWithExplicitIdentifier(agrees: Bool) async throws {
    let scenario = try CorrectionScenario(name: "Wrong Movie [imdb:tt0078748]")
    defer { scenario.cleanup() }
    try scenario.save(FolderSearchCorrection(title: "Dune", year: 2021))
    let identifierMovie = MovieMetadata(id: agrees ? 42 : 348, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
      posterPath: "/poster.jpg")
    let provider = CountingProvider(imdbMovies: ["tt0078748": identifierMovie])
    let summary = try await scenario.processor(provider: provider)
      .process(root: scenario.fixture.movies, processingContext: scenario.context)

    #expect(summary.assigned == (agrees ? 1 : 0))
    #expect(await provider.imdbLookups == ["tt0078748"])
    #expect(await provider.posterCount == (agrees ? 1 : 0))
    if !agrees { #expect(try scenario.record()?.processingReason == .conflictingMovieInformation) }
  }

  /// Final identifier reconciliation supersedes a preliminary successful corrected-title match.
  @Test(arguments: [0, 1, 2, 3])
  func correctionDiagnosticsRetainFinalIdentifierDecision(_ disposition: Int) async throws {
    let scenario = try CorrectionScenario(name: "Wrong Movie [imdb:tt0078748]")
    defer { scenario.cleanup() }
    try scenario.save(FolderSearchCorrection(title: "Dune", year: 2021))
    let history = ProcessingActivityProbe()
    let identified = MovieMetadata(id: disposition == 0 ? 42 : 348, title: "Dune", originalTitle: "Dune",
      releaseYear: 2021, posterPath: "/poster.jpg")
    let lookups: [String: MovieMetadata?] = disposition == 3 ? [:]
      : ["tt0078748": disposition == 2 ? .none : identified]
    let provider = CountingProvider(imdbMovies: lookups)
    let directory = MonitoredDirectory(id: scenario.context.rootID, path: scenario.fixture.movies.path,
      transferBookmark: Data(), authorizationVersion: UUID())
    let processor = MovieFolderProcessor(persistence: scenario.fixture.persistence, provider: provider,
      cacheDirectory: scenario.fixture.cache, posterAssigner: scenario.fixture.assigner,
      activityHistoryService: history, activityLogContext: .init(directory: directory),
      searchCorrectionStore: scenario.corrections)
    _ = try await processor.process(root: scenario.fixture.movies, processingContext: scenario.context)
    let diagnostics = try #require(await history.events.first?.matchingDiagnostics)
    let outcomes: [MovieMatchingDiagnostics.Outcome] = [
      .matched, .identifierConflict, .identifierNotFound, .notEvaluated
    ]
    #expect(diagnostics.outcome == outcomes[disposition])
    #expect(diagnostics.source == .savedSearchCorrection)
    #expect(diagnostics.query?.title == "Dune")
    #expect(diagnostics.candidates.first?.verdict == .compatible)
    #expect(await provider.posterCount == (disposition == 0 ? 1 : 0))
  }

  /// A save-and-clear cycle or a changed correction during artwork cannot authorize the stale attempt.
  @Test(arguments: [false, true])
  func correctionChangesInterruptInFlightAssignment(duringArtwork: Bool) async throws {
    let scenario = try CorrectionScenario(name: "Dune (2021)")
    defer { scenario.cleanup() }
    let provider = CountingProvider(delaysSearch: !duringArtwork, delaysPoster: duringArtwork)
    let processor = scenario.processor(provider: provider)
    let task = Task { try await processor.process(root: scenario.fixture.movies, processingContext: scenario.context) }
    if duringArtwork { await provider.waitForPoster() } else { await provider.waitForSearch() }
    try scenario.save(FolderSearchCorrection(title: "Different movie", year: .none))
    if duringArtwork {
      try await provider.allowPoster()
    } else {
      try scenario.save(.none)
      await provider.allowSearch()
    }

    #expect(try await task.value.assigned == 0)
    #expect(scenario.fixture.assigner.assignmentCount == 0)
    #expect(try scenario.record()?.matchedMovieID == .none)
  }

  /// Clearing a correction reopens the folder, while a sibling edit keeps its cached outcome.
  @Test func onlyEffectiveFolderEditsReopenItsAssessment() async throws {
    let scenario = try CorrectionScenario(name: "Dune (2021)")
    defer { scenario.cleanup() }
    let wrong = try FolderSearchCorrection(title: "Wrong movie", year: .none)
    try scenario.save(wrong)
    let provider = CountingProvider(search: .init(movies: [Self.dune], hasMorePages: false))
    let processor = scenario.processor(provider: provider)
    let first = try await processor.process(root: scenario.fixture.movies, processingContext: scenario.context)
    #expect(first.unresolved == 1)

    try scenario.corrections.setCorrection(wrong, for: "sibling", in: scenario.context.rootID)
    try scenario.save(wrong)
    let unchanged = try await processor.process(root: scenario.fixture.movies, processingContext: scenario.context)
    #expect(unchanged.unresolved == 1)
    #expect(unchanged.examined == 0)

    try scenario.save(.none)
    let cleared = try await processor.process(root: scenario.fixture.movies, processingContext: scenario.context)
    #expect(cleared.assigned == 1)
    #expect(try scenario.record()?.movieIdentitySource == .conservativeMatch)
  }

  /// A selected retry uses changed corrected evidence to reopen an existing inconclusive outcome.
  @Test func selectedRetryUsesNewSavedCorrection() async throws {
    let scenario = try ManualResolutionScenario(isAmbiguous: false)
    let fixture = scenario.fixture
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let context = scenario.processingContext
    let initial = try await scenario.processor.process(root: fixture.movies, processingContext: context)
    #expect(initial.unresolved == 1)
    let name = "Dune (2021)"
    let service = FileSystemService()
    let candidate = try service.readCurrentFolderCandidate(ofChild: name, in: fixture.movies)
    let identity = try service.verifiedFolderIdentity(
      at: fixture.movies.appendingPathComponent(name), expectedIdentity: candidate.identity)
    let corrections = FolderSearchCorrectionStore(store: try PersistenceStore(
      directory: fixture.base.appendingPathComponent("Corrections")))
    try corrections.setCorrection(FolderSearchCorrection(title: "Alien", year: 1979),
      for: identity, in: context.rootID)
    let provider = CountingProvider(primaryReleaseYear: 1979)
    let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
      cacheDirectory: fixture.cache, posterAssigner: fixture.assigner, processingStore: scenario.collectionStore,
      searchCorrectionStore: corrections)
    let result = try await processor.retryEligibleFolder(root: fixture.movies, child: name,
      expectedIdentity: candidate.identity, processingContext: context)

    guard case .attempted(let summary, _) = result else { Issue.record("Expected an eligible retry."); return }

    #expect(summary.assigned == 1)
    let outcome = try scenario.collectionStore.read(rootID: context.rootID)?.folders.first
    #expect(outcome?.matchedMovieTitle == "Alien")
    #expect(outcome?.movieIdentitySource == .savedSearchCorrection)
  }

  /// A corrected match that failed during artwork cannot protect or restore a provisional ID after an edit.
  @Test func changedCorrectionReplacesProvisionalArtworkEvidence() async throws {
    let scenario = try CorrectionScenario()
    defer { scenario.cleanup() }
    try scenario.save(FolderSearchCorrection(title: "Dune", year: 2021))
    let failed = scenario.processor(provider: CountingProvider(posterError: .invalidImage))
    let failedResult = try await failed.process(root: scenario.fixture.movies, processingContext: scenario.context)
    #expect(failedResult.assigned == 0)
    #expect(try scenario.record()?.provisionalCorrectedMatch == true)
    #expect(try scenario.record()?.matchedMovieID == 42)

    let alien = MovieMetadata(id: 348, title: "Alien", originalTitle: "Alien", releaseYear: 1979,
      posterPath: "/alien.jpg")
    try scenario.save(FolderSearchCorrection(title: "Alien", year: 1979))
    let next = scenario.processor(provider: CountingProvider(search: .init(movies: [alien], hasMorePages: false)))
    let result = try await next.process(root: scenario.fixture.movies, processingContext: scenario.context)
    #expect(result.assigned == 1)
    #expect(try scenario.record()?.matchedMovieID == 348)
    #expect(try scenario.record()?.provisionalCorrectedMatch == .none)
  }

  /// A saved correction cannot reopen a confirmed identity or replace a foreign icon.
  @Test(arguments: [false, true])
  func correctionsPreserveExistingPosterDecisions(hasForeignIcon: Bool) async throws {
    let scenario = try CorrectionScenario(name: "Dune (2021)")
    defer { scenario.cleanup() }
    if hasForeignIcon {
      try scenario.fixture.markCustomIcon(scenario.name)
    } else {
      let initial = scenario.processor(provider: CountingProvider())
      _ = try await initial.process(root: scenario.fixture.movies, processingContext: scenario.context)
    }
    let assignments = scenario.fixture.assigner.assignmentCount
    try scenario.save(FolderSearchCorrection(title: "Alien", year: 1979))
    let provider = CountingProvider(primaryReleaseYear: 1979)
    let processor = scenario.processor(provider: provider)
    _ = try await processor.process(root: scenario.fixture.movies, processingContext: scenario.context)

    #expect(await provider.searchCount == 0)
    if hasForeignIcon {
      #expect(scenario.fixture.assigner.assignmentCount == assignments)
    } else {
      #expect(try scenario.record()?.matchedMovieID == 42)
    }
  }

  /// A corrected year is never filled from the folder when the user leaves it blank.
  @Test func blankCorrectionDoesNotSatisfyRequiredYear() async throws {
    let scenario = try CorrectionScenario(name: "Dune (2021)")
    defer { scenario.cleanup() }
    try scenario.save(FolderSearchCorrection(title: "Dune", year: .none))
    let provider = CountingProvider()
    let processor = scenario.processor(provider: provider,
      matching: MovieMatchingConfiguration(requiresReleaseYearForAutomaticMatching: true))
    let result = try await processor.process(root: scenario.fixture.movies, processingContext: scenario.context)
    #expect(result.unresolved == 1)
    #expect(await provider.searchCount == 0)
    #expect(try scenario.record()?.processingReason == .manualMatchingRequired)
  }

  /// Missing identifier evidence and incomplete search results cannot authorize assignment.
  @Test(arguments: [false, true])
  func incompleteCorrectedEvidenceLeavesFolderUnresolved(incompleteSearch: Bool) async throws {
    let scenario = try CorrectionScenario(name: "Wrong Movie [imdb:tt0078748]")
    defer { scenario.cleanup() }
    try scenario.save(FolderSearchCorrection(title: "Dune", year: 2021))
    let provider = CountingProvider(search: .init(movies: [Self.dune], hasMorePages: incompleteSearch),
      imdbMovies: ["tt0078748": .none])
    let result = try await scenario.processor(provider: provider)
      .process(root: scenario.fixture.movies, processingContext: scenario.context)

    #expect(result.assigned == 0)
    #expect(result.unresolved == 1)
    #expect(await provider.posterCount == 0)
    #expect(try scenario.record()?.processingReason == (incompleteSearch ? .incompleteSearch : .noSuitableMovie))
  }

  /// A correction edit cannot bypass a collection-wide provider deadline.
  @Test func correctionRespectsProviderBackoff() async throws {
    let scenario = try CorrectionScenario(name: "Dune (2021)")
    defer { scenario.cleanup() }
    let provider = CountingProvider(searchError: .rateLimited(retryAfter: "120"))
    let processor = scenario.processor(provider: provider)
    let initial = try await processor.process(root: scenario.fixture.movies, processingContext: scenario.context)
    #expect(initial.providerRetryAt != .none)

    try scenario.save(FolderSearchCorrection(title: "Alien", year: 1979))
    let deferred = try await processor.process(root: scenario.fixture.movies, processingContext: scenario.context)
    #expect(deferred.assigned == 0)
    #expect(await provider.searchCount == 1)
  }

  /// A corrupt correction record stops automatic matching before any provider request.
  @Test func unreadableCorrectionsDoNotFallBackToFolderName() async throws {
    let scenario = try CorrectionScenario(name: "Dune (2021)")
    defer { scenario.cleanup() }
    let store = try PersistenceStore(directory: scenario.fixture.base.appendingPathComponent("Corrections"))
    do {
      let access = try #require(try store.acquireAccess(for: "folder-search-corrections:\(scenario.context.rootID)"))
      try access.write(Data("{".utf8))
    }
    let provider = CountingProvider()
    let processor = scenario.processor(provider: provider)
    await #expect(throws: DecodingError.self) {
      try await processor.process(root: scenario.fixture.movies, processingContext: scenario.context)
    }
    #expect(await provider.searchCount == 0)
    #expect(scenario.fixture.assigner.assignmentCount == 0)
  }

  /// A change at final authorization is seen by the synchronous assignment check.
  @Test func correctionIsRecheckedAtFinalAssignment() async throws {
    let scenario = try CorrectionScenario(name: "Dune (2021)")
    defer { scenario.cleanup() }
    let verifier = CorrectionChangingVerifier(scenario: scenario)
    let processor = scenario.processor(provider: CountingProvider(), verifier: verifier)
    let result = try await processor.process(root: scenario.fixture.movies, processingContext: scenario.context)
    #expect(result.assigned == 0)
    #expect(scenario.fixture.assigner.assignmentCount == 0)
    #expect(try scenario.record()?.processingReason == .interrupted)
  }

  /// A due incomplete search bypasses cached partial results for the corrected title.
  @Test func correctedIncompleteSearchRequestsFreshProviderResults() async throws {
    let scenario = try CorrectionScenario()
    defer { scenario.cleanup() }
    let clock = TestClock(Date())
    let timing = try MovieFolderProcessorConfiguration(incompleteSearchRetryInterval: 1,
      transientFailureRetryInterval: 1, queryCacheLifetime: 3_600, minimumProviderRetryInterval: 1,
      maximumProviderRetryInterval: 600)
    try scenario.save(FolderSearchCorrection(title: "Dune", year: 2021))
    let partial = CountingProvider(search: .init(movies: [Self.dune], hasMorePages: true))
    let first = scenario.processor(provider: partial, now: { clock.now }, timing: timing)
    _ = try await first.process(root: scenario.fixture.movies, processingContext: scenario.context)
    #expect(try scenario.record()?.processingReason == .incompleteSearch)
    clock.advance(by: 2)

    let provider = CountingProvider()
    let next = scenario.processor(provider: provider, now: { clock.now }, timing: timing)
    let result = try await next.process(root: scenario.fixture.movies, processingContext: scenario.context)
    #expect(await provider.searchCount == 1)
    #expect(result.assigned == 1)
  }

  /// Failure repairing cached artwork retains the earlier confirmed identity after a correction edit.
  @Test func repairFailureDoesNotMakeConfirmedIdentityProvisional() async throws {
    let scenario = try CorrectionScenario(name: "Dune (2021)")
    defer { scenario.cleanup() }
    let initial = scenario.processor(provider: CountingProvider())
    _ = try await initial.process(root: scenario.fixture.movies, processingContext: scenario.context)
    try FileManager.default.removeItem(at: scenario.fixture.cache)
    try scenario.save(FolderSearchCorrection(title: "Alien", year: 1979))

    let repair = scenario.processor(provider: CountingProvider(posterError: .invalidImage))
    _ = try await repair.process(root: scenario.fixture.movies, processingContext: scenario.context)
    #expect(try scenario.record()?.matchedMovieID == 42)
    #expect(try scenario.record()?.provisionalCorrectedMatch == .none)

    try scenario.save(FolderSearchCorrection(title: "Another movie", year: 1980))
    let provider = CountingProvider(primaryReleaseYear: 1980)
    let next = scenario.processor(provider: provider)
    _ = try await next.process(root: scenario.fixture.movies, processingContext: scenario.context)
    #expect(await provider.searchCount == 0)
    #expect(try scenario.record()?.matchedMovieID == 42)
  }

  /// A preserved icon does not turn uninstalled corrected artwork into a confirmed identity.
  @Test func preservedIconDoesNotConfirmTheCorrectedMatch() async throws {
    let scenario = try CorrectionScenario()
    defer { scenario.cleanup() }
    try scenario.save(FolderSearchCorrection(title: "Dune", year: 2021))
    let processor = scenario.processor(provider: CountingProvider(), assigner: PreservingCorrectionAssigner())
    let result = try await processor.process(root: scenario.fixture.movies, processingContext: scenario.context)
    #expect(result.assigned == 0)
    #expect(try scenario.record()?.matchedMovieID == .none)
  }

  /// Replacing a folder at the same path does not transfer its saved search fields.
  @Test func replacementFolderUsesItsOwnName() async throws {
    let scenario = try CorrectionScenario(name: "Dune (2021)")
    defer { scenario.cleanup() }
    try scenario.save(FolderSearchCorrection(title: "Alien", year: 1979))
    let original = scenario.fixture.movies.appendingPathComponent(scenario.name)
    try FileManager.default.moveItem(at: original, to: scenario.fixture.base.appendingPathComponent("Original"))
    try scenario.fixture.addFolder(scenario.name)
    let processor = scenario.processor(provider: CountingProvider())

    let result = try await processor.process(root: scenario.fixture.movies, processingContext: scenario.context)
    #expect(result.assigned == 1)
    #expect(try scenario.record()?.movieTitle == "Dune")
    #expect(try scenario.record()?.movieIdentitySource == .conservativeMatch)
  }

  /// A correction change during metadata enrichment prevents the next provider step and any assignment.
  @Test func correctionChangeDuringMetadataInterruptsMatching() async throws {
    let scenario = try CorrectionScenario()
    defer { scenario.cleanup() }
    try scenario.save(FolderSearchCorrection(title: "Dune", year: 2021))
    let provider = CorrectionChangingMetadataProvider(scenario: scenario)
    let processor = scenario.processor(provider: provider)
    let result = try await processor.process(root: scenario.fixture.movies, processingContext: scenario.context)

    #expect(result.assigned == 0)
    #expect(await provider.source.posterCount == 0)
    #expect(try scenario.record()?.processingReason == .interrupted)
  }

  /// Cancelling a corrected search while its provider request is suspended prevents assignment.
  @Test func cancelledCorrectedSearchDoesNotAssign() async throws {
    let scenario = try CorrectionScenario()
    defer { scenario.cleanup() }
    try scenario.save(FolderSearchCorrection(title: "Dune", year: 2021))
    let provider = CountingProvider(delaysSearch: true)
    let processor = scenario.processor(provider: provider)
    let task = Task { try await processor.process(root: scenario.fixture.movies, processingContext: scenario.context) }
    await provider.waitForSearch()
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(scenario.fixture.assigner.assignmentCount == 0)
    #expect(await provider.posterCount == 0)
  }

  /// The unique provider response used across the corrected search fixtures.
  private static let dune = MovieMetadata(id: 42, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
    posterPath: "/dune.jpg")
}

/// Saves a correction while returning an ordinary provider metadata response.
private struct CorrectionChangingMetadataProvider: MovieMetadataProvider {
  /// Temporary collection whose correction changes during enrichment.
  let scenario: CorrectionScenario
  /// Provider used to record search and artwork requests.
  let source = CountingProvider()

  /// Returns one unique search result from the counting fixture.
  func searchMoviePage(title: String, year: Int?, language: MovieSearchLanguage, page: Int) async throws
    -> MovieSearchPage {
    try await source.searchMoviePage(title: title, year: year, language: language, page: page)
  }

  /// Changes the correction before handing alias evidence back to matching.
  func alternativeTitles(movieID: Int) async throws -> MovieAlternativeTitlesByID {
    try scenario.save(.none)

    return try await source.alternativeTitles(movieID: movieID)
  }

  /// Forwards release date evidence.
  func releaseDates(movieID: Int) async throws -> MovieReleaseDatesByID {
    try await source.releaseDates(movieID: movieID)
  }

  /// Forwards artwork requests so the test can detect an unexpected download.
  func downloadPoster(path: String) async throws -> Data { try await source.downloadPoster(path: path) }
}

/// Models an existing icon appearing at the synchronous assignment boundary.
private struct PreservingCorrectionAssigner: PosterAssigner {
  /// Reports preservation without making an icon change.
  func assignPoster(
    _ data: Data, toChild name: String, in directory: URL, expectedIdentity: String?
  ) throws -> FolderPosterAssignmentResult { .existingIconPreserved }
}

/// Edits the correction when assignment reaches the live authorization boundary.
private struct CorrectionChangingVerifier: MovieFolderProcessingVerifier {
  /// Isolated folder and correction store to edit.
  let scenario: CorrectionScenario

  /// Allows the fixture to start automatic processing.
  func checkAutomaticProcessing(in root: URL) throws -> PersistenceAccess? { .none }

  /// Simulates an edit immediately before the final settings check returns.
  func checkIconChange(
    _ change: MovieFolderIconChange, to candidate: MovieFolderCandidate, in root: URL
  ) throws -> PersistenceAccess? {
    if change == .automaticPosterAssignment {
      try scenario.save(FolderSearchCorrection(title: "Alien", year: 1979))
    }

    return .none
  }
}

/// Holds a disposable collection and its real correction and operational stores.
private struct CorrectionScenario: Sendable {
  /// Filesystem and operational fixtures shared with the processor tests.
  let fixture: Fixture
  /// Configured collection identity carried by the processor.
  let context: CollectionProcessingContext
  /// The shared correction store opened on isolated storage.
  let corrections: FolderSearchCorrectionStore
  /// The selected immediate child name.
  let name: String
  /// Verified identity used for correction writes.
  let identity: String

  /// Creates one authorized folder and its correction namespace.
  init(name: String = "Wrong Movie (2021)") throws {
    fixture = try Fixture()
    self.name = name
    try fixture.addFolder(name)
    let fileSystem = FileSystemService()
    let child = fixture.movies.appendingPathComponent(name)
    let candidate = try fileSystem.readCurrentFolderCandidate(ofChild: name, in: fixture.movies)
    identity = try fileSystem.verifiedFolderIdentity(at: child, expectedIdentity: candidate.identity)
    context = CollectionProcessingContext(rootID: UUID(),
      rootIdentity: try fileSystem.persistentDirectoryIdentity(at: fixture.movies),
      authorizationVersion: UUID(), credentialRevision: UUID(), usesStubTMDbResponses: false, appearance: .softFinish)
    corrections = FolderSearchCorrectionStore(store: try PersistenceStore(
      directory: fixture.base.appendingPathComponent("Corrections")))
  }

  /// Creates a processor using the isolated correction namespace and the supplied provider.
  func processor(
    provider: any MovieMetadataProvider, matching: MovieMatchingConfiguration = .init(),
    verifier: (any MovieFolderProcessingVerifier)? = .none, assigner: (any PosterAssigner)? = .none,
    now: @escaping @Sendable () -> Date = Date.init, timing: MovieFolderProcessorConfiguration = .standard
  ) -> MovieFolderProcessor {
    MovieFolderProcessor(persistence: fixture.persistence, provider: provider, cacheDirectory: fixture.cache,
      posterAssigner: assigner ?? fixture.assigner, now: now, processingVerifier: verifier, configuration: timing,
      movieMatchingConfiguration: matching, searchCorrectionStore: corrections)
  }

  /// Writes corrected fields for the selected folder.
  func save(_ correction: FolderSearchCorrection?) throws {
    try corrections.setCorrection(correction, for: identity, in: context.rootID)
  }

  /// Reads the last operational decision for the selected folder.
  func record() throws -> FolderProcessingCacheRecord? {
    let key = MovieFolderProcessor.processingStateKey(for: fixture.movies)
    let access = try #require(try fixture.persistence.acquireAccess(for: key))
    let data = try #require(try access.read())

    return try JSONDecoder().decode(CollectionProcessingCache.self, from: data).folders[name]
  }

  /// Removes all disposable test data.
  func cleanup() { try? FileManager.default.removeItem(at: fixture.base) }
}
