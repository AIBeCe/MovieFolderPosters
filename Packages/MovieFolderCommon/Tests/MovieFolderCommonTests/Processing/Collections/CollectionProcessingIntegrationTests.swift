import FileSystem
import Foundation
import Network
import Persistence
import Testing

@testable import MovieFolderCommon

/// Checks durable results through the production processor and real local stores.
struct CollectionProcessingIntegrationTests {
  /// A cache-save failure records the actual verified poster and stops before the next folder change.
  @Test func automaticCacheFailurePreservesActualInstalledEvidence() async throws {
    let fixture = try CollectionProcessingFixture(names: ["Alpha (2021)", "Beta (2021)"])
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    #if SWIFT_PACKAGE
      let image = try #require(Bundle.module.url(forResource: "TestPoster", withExtension: "png"))
    #else
      let image = try #require(
        Bundle(for: MoviePosterActionTests.self).url(forResource: "TestPoster", withExtension: "png"))
    #endif
    let processor = MovieFolderProcessor(
      persistence: fixture.processing,
      provider: CollectionProcessingMetadataProvider(posterData: try Data(contentsOf: image)),
      cacheDirectory: fixture.base.appendingPathComponent("Posters"),
      posterAssigner: CacheFailurePosterAssigner(directory: fixture.base.appendingPathComponent("Processing")),
      processingLockStore: fixture.coordination, processingStore: fixture.processingStore)
    do {
      _ = try await processor.process(root: fixture.root, processingContext: fixture.context)
      Issue.record("A broken processing cache must stop this attempt")
    } catch CollectionProcessingError.unavailable {}
    let processingState = try #require(try fixture.processingStore.read(rootID: fixture.context.rootID))
    let alpha = try #require(processingState.folders.first { $0.folderName == "Alpha (2021)" })
    #expect(alpha.processingState == .done)
    #expect(alpha.processingReason == .cachePersistenceFailure)
    #expect(alpha.lastFailure?.stage == .persist)
    #expect(processingState.currentRun?.runState == .failed)
    #expect(try FileSystemService().hasAssignedPoster(toChild: "Alpha (2021)", in: fixture.root))
    #expect(try !FileSystemService().readCurrentFolderCandidate(ofChild: "Beta (2021)", in: fixture.root).hasCustomIcon)
  }

  /// A result-store failure after a real assignment retains both operation success and failed persistence.
  @Test func authoritativePersistenceFailureRetainsActualOperationHistory() async throws {
    let fixture = try CollectionProcessingFixture(names: ["Movie (2021)"])
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    #if SWIFT_PACKAGE
      let image = try #require(Bundle.module.url(forResource: "TestPoster", withExtension: "png"))
    #else
      let image = try #require(
        Bundle(for: MoviePosterActionTests.self).url(forResource: "TestPoster", withExtension: "png"))
    #endif
    let configuration = ConfigurationRepository(
      store: try PersistenceStore(directory: fixture.base.appendingPathComponent("Settings")))
    let directory = try #require(try configuration.read().directories.first)
    let activity = ProcessingActivityProbe()
    let processor = MovieFolderProcessor(
      persistence: fixture.processing,
      provider: CollectionProcessingMetadataProvider(posterData: try Data(contentsOf: image)),
      cacheDirectory: fixture.base.appendingPathComponent("Posters"),
      posterAssigner: CacheFailurePosterAssigner(directory: fixture.base.appendingPathComponent("Outcomes")),
      processingLockStore: fixture.coordination, processingStore: fixture.processingStore,
      activityHistoryService: activity, activityLogContext: MovieFolderActivityLogContext(directory: directory))
    await #expect(throws: CollectionProcessingError.unavailable) {
      try await processor.process(root: fixture.root, processingContext: fixture.context)
    }
    let events = await activity.events
    #expect(events.contains { $0.folderResult == .posterApplied && $0.target?.movieID == 7 })
    let failure = try #require(events.first { $0.folderResult == .failed })
    #expect(failure.target?.childFolderName == "Movie (2021)")
    #expect(failure.target?.movieID == 7)
    #expect(failure.failure?.stage == .persist)
    #expect(failure.failure?.reason == .storage)
    #expect(try FileSystemService().hasAssignedPoster(toChild: "Movie (2021)", in: fixture.root))
  }

  /// Manual selection/removal share collection evidence without claiming a new full collection run.
  @Test func manualActionsUpdateVerifiedStateAndPreserveCollectionRun() async throws {
    let fixture = try CollectionProcessingFixture(names: ["Missing (2021)"])
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    _ = try await fixture.processor(provider: CollectionProcessingMetadataProvider()).process(
      root: fixture.root, processingContext: fixture.context)
    let before = try #require(try fixture.processingStore.read(rootID: fixture.context.rootID))
    #if SWIFT_PACKAGE
      let image = try #require(Bundle.module.url(forResource: "TestPoster", withExtension: "png"))
    #else
      let image = try #require(
        Bundle(for: MoviePosterActionTests.self).url(forResource: "TestPoster", withExtension: "png"))
    #endif
    let provider = CollectionProcessingMetadataProvider(posterData: try Data(contentsOf: image))
    let processor = fixture.processor(provider: provider)
    let identity = try FileSystemService().readCurrentFolderCandidate(ofChild: "Missing (2021)", in: fixture.root).identity
    let movie = MovieMetadata(
      id: 7, title: "Chosen", originalTitle: "Chosen", releaseYear: 2021, posterPath: "/chosen.jpg")
    _ = try await processor.applyMoviePoster(
      movie, root: fixture.root, child: "Missing (2021)", expectedIdentity: identity,
      processingContext: fixture.context)
    let selected = try #require(try fixture.processingStore.read(rootID: fixture.context.rootID))
    #expect(selected.folders.first?.processingState == .done)
    #expect(selected.folders.first?.matchedMovieID == 7)
    #expect(selected.folders.first?.ownership == .owned)
    #expect(selected.calculateCounts().done == 1)
    #expect(selected.currentRun?.action == .selection)
    #expect(selected.lastCompletedRun == before.lastCompletedRun)

    // A download failure must not erase a currently verified installed poster.
    let failing = fixture.processor(provider: CollectionProcessingMetadataProvider())
    do {
      _ = try await failing.refreshPoster(
        root: fixture.root, child: "Missing (2021)", expectedIdentity: identity, processingContext: fixture.context)
      Issue.record("The controlled poster download must fail")
    } catch TMDbError.invalidPosterPath {}
    let failedRefresh = try #require(try fixture.processingStore.read(rootID: fixture.context.rootID))
    #expect(failedRefresh.folders.first?.processingState == .done)
    #expect(failedRefresh.folders.first?.lastFailure != .none)
    #expect(failedRefresh.currentRun?.runState == .failed)

    _ = try await processor.removePoster(
      root: fixture.root, child: "Missing (2021)", expectedIdentity: identity, processingContext: fixture.context)
    let removed = try #require(try fixture.processingStore.read(rootID: fixture.context.rootID))
    #expect(removed.folders.first?.processingState == .suppressed)
    #expect(removed.calculateCounts().done == 0)
    #expect(removed.lastCompletedRun == before.lastCompletedRun)
  }

  /// Readers observe committed membership during provider work, and cancellation leaves no fabricated result.
  @Test func cancellationPersistsInterruptedPendingWork() async throws {
    let fixture = try CollectionProcessingFixture(names: ["Waiting (2021)"])
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let provider = BlockingCollectionProcessingMetadataProvider()
    let processor = fixture.processor(provider: provider)
    let task = Task { try await processor.process(root: fixture.root, processingContext: fixture.context) }
    await provider.waitForSearch()
    let running = try #require(try fixture.processingStore.read(rootID: fixture.context.rootID))
    #expect(running.currentRun?.runState == .running)
    #expect(running.calculateCounts().total == 1)
    #expect(running.calculateCounts().notFound == .none)
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Cancellation must propagate")
    } catch is CancellationError {}
    let interrupted = try #require(try fixture.processingStore.read(rootID: fixture.context.rootID))
    #expect(interrupted.currentRun?.runState == .interrupted)
    #expect(interrupted.folders.first?.processingState == .uncertain)
    #expect(interrupted.lastCompletedRun == .none)
  }

  /// Complete negative and ambiguous searches remain distinguishable after reopening storage.
  @Test func distinctMatchingResultsSurviveReopening() async throws {
    let fixture = try CollectionProcessingFixture(names: ["Missing (2021)", "Ambiguous (2021)", "Incomplete (2021)"])
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let processor = fixture.processor(provider: CollectionProcessingMetadataProvider())
    let summary = try await processor.process(root: fixture.root, processingContext: fixture.context)
    let processingState = try #require(try fixture.processingStore.read(rootID: fixture.context.rootID))
    let records = Dictionary(uniqueKeysWithValues: processingState.folders.map { ($0.folderName, $0) })
    #expect(records["Missing (2021)"]?.processingState == .notFound)
    #expect(records["Ambiguous (2021)"]?.processingState == .severalMatches)
    #expect(records["Incomplete (2021)"]?.processingReason == .incompleteSearch)
    #expect(summary.nextAutomaticRetryAt == records["Incomplete (2021)"]?.nextRetryAt)
    #expect(processingState.calculateCounts().total == 3)
    #expect(processingState.calculateCounts().notFound == 1)
    #expect(processingState.calculateCounts().severalMatches == 1)
    #expect(processingState.currentRun?.runState == .completed)
  }

  /// Conclusive negative and ambiguous matches never arm an automatic retry.
  @Test func conclusiveResultsDoNotScheduleAutomaticRetry() async throws {
    let fixture = try CollectionProcessingFixture(names: ["Missing (2021)", "Ambiguous (2021)"])
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let summary = try await fixture.processor(provider: CollectionProcessingMetadataProvider()).process(
      root: fixture.root, processingContext: fixture.context)

    #expect(summary.nextAutomaticRetryAt == .none)
  }

  /// An established empty inventory is different from a missing summary.
  @Test func emptyCollectionEstablishesRealZeros() async throws {
    let fixture = try CollectionProcessingFixture(names: [])
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    #expect(try fixture.processingStore.read(rootID: fixture.context.rootID) == .none)
    _ = try await fixture.processor(provider: CollectionProcessingMetadataProvider()).process(
      root: fixture.root, processingContext: fixture.context)
    let processingState = try #require(try fixture.processingStore.read(rootID: fixture.context.rootID))
    #expect(processingState.calculateCounts().total == 0)
    #expect(processingState.calculateCounts().done == 0)
    #expect(processingState.lastCompletedRun?.runState == .completed)
  }

  /// Authentication backoff stops the traversal without inventing processingStore for unvisited folders.
  @Test func providerBackoffPersistsPartialTraversal() async throws {
    let fixture = try CollectionProcessingFixture(names: ["First (2021)", "Second (2021)"])
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let provider = CollectionProcessingMetadataProvider(authenticationFailure: true)
    _ = try await fixture.processor(provider: provider).process(
      root: fixture.root, processingContext: fixture.context)
    let processingState = try #require(try fixture.processingStore.read(rootID: fixture.context.rootID))
    #expect(processingState.currentRun?.runState == .partial)
    #expect(processingState.lastCompletedRun == .none)
    #expect(processingState.folders.contains { $0.processingState == .pending || $0.processingState == .deferred })
    #expect(processingState.folders.contains { $0.processingReason == .authentication })
  }

  /// Neither a new authentication failure nor cached rejection can fabricate a completed collection run.
  @Test(arguments: [false, true])
  func authenticationAdmissionPreservesPartialTraversal(cachedRejection: Bool) async throws {
    let fixture = try CollectionProcessingFixture(names: ["First (2021)", "Second (2021)"])
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let recovery = ProcessingRecoveryService(
      store: try PersistenceStore(directory: fixture.base.appendingPathComponent("Recovery")))
    let provider = RecoveryAwareMovieMetadataProvider(
      provider: CollectionProcessingMetadataProvider(authenticationFailure: true),
      recovery: recovery, credential: "token")
    if cachedRejection {
      await #expect(throws: TMDbError.authentication) { try await provider.searchMovies(title: "Warmup", year: .none) }
    }
    let processor = MovieFolderProcessor(
      persistence: fixture.processing, provider: provider,
      cacheDirectory: fixture.base.appendingPathComponent("Posters"),
      processingLockStore: fixture.coordination, processingStore: fixture.processingStore, recovery: recovery)

    _ = try await processor.process(root: fixture.root, processingContext: fixture.context)

    let state = try #require(try fixture.processingStore.read(rootID: fixture.context.rootID))
    #expect(state.currentRun?.runState == .partial)
    #expect(state.lastCompletedRun == .none)
    #expect(state.folders.contains { $0.processingState == .pending })
    #expect(state.folders.contains { $0.processingReason == .authentication })
  }
  /// An explicit refresh cannot replace unchanged confirmed identity or hide its manual-resolution result.
  @Test func refreshIdentityConflictRetainsDecisionAndManualResult() async throws {
    let fixture = try CollectionProcessingFixture(names: ["Movie (2021)"])
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let candidate = try FileSystemService().readCurrentFolderCandidate(ofChild: "Movie (2021)", in: fixture.root)
    let previous = FolderProcessingCacheRecord(fingerprint: candidate.fingerprint, status: .processed,
      matchedMovieID: 42, posterPath: "/previous.jpg", movieTitle: "Prior identity", movieYear: 2021,
      movieIdentitySource: .conservativeMatch, requiresAutomaticReview: true)
    do {
      let access = try #require(try fixture.processing.acquireAccess(for:
        MovieFolderProcessor.processingStateKey(for: fixture.root)))
      try access.write(JSONEncoder().encode(CollectionProcessingCache(folders: [candidate.name: previous])))
    }
    let provider = CountingProvider(search: MovieSearchResult(movies: [MovieMetadata(id: 43, title: "Movie",
      originalTitle: "Movie", releaseYear: 2021, posterPath: "/replacement.jpg")], hasMorePages: false))
    let processor = fixture.processor(provider: provider)
    await #expect(throws: PosterActionError.unresolved) {
      try await processor.refreshPoster(root: fixture.root, child: candidate.name, expectedIdentity: candidate.identity,
        processingContext: fixture.context)
    }
    #expect(await provider.posterCount == 0)
    #expect(try !FileSystemService().readCurrentFolderCandidate(ofChild: candidate.name, in: fixture.root).hasCustomIcon)
    let access = try #require(try fixture.processing.acquireAccess(for:
      MovieFolderProcessor.processingStateKey(for: fixture.root)))
    let saved = try await processor.loadState(from: access).folders[candidate.name]
    #expect(saved?.matchedMovieID == 42)
    #expect(saved?.posterPath == "/previous.jpg")
    #expect(saved?.movieIdentitySource == .conservativeMatch)
    #expect(saved?.processingReason == .manualMatchingRequired)
    let result = try #require(try fixture.processingStore.read(rootID: fixture.context.rootID)).folders.first
    #expect(result?.processingState == .unresolved)
    #expect(result?.processingReason == .manualMatchingRequired)
    #expect(result?.matchedMovieID == 42)
    #expect(result?.movieIdentitySource == .conservativeMatch)
  }

  /// A prior manual-resolution result cannot donate identity to a changed folder after a fresh refresh fails.
  @Test func refreshFailureDoesNotProjectIdentityAcrossChangedFingerprint() async throws {
    let fixture = try CollectionProcessingFixture(names: ["Movie (2021)"])
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let candidate = try FileSystemService().readCurrentFolderCandidate(ofChild: "Movie (2021)", in: fixture.root)
    let previous = FolderProcessingCacheRecord(fingerprint: "obsolete", status: .unresolved,
      matchedMovieID: 42, posterPath: "/previous.jpg", processingReason: .manualMatchingRequired,
      movieTitle: "Prior identity", movieYear: 2021, movieIdentitySource: .conservativeMatch)
    do {
      let access = try #require(try fixture.processing.acquireAccess(for:
        MovieFolderProcessor.processingStateKey(for: fixture.root)))
      try access.write(JSONEncoder().encode(CollectionProcessingCache(folders: [candidate.name: previous])))
    }
    let provider = CountingProvider(searchError: .authentication)
    let processor = fixture.processor(provider: provider)
    await #expect(throws: TMDbError.authentication) {
      try await processor.refreshPoster(root: fixture.root, child: candidate.name, expectedIdentity: candidate.identity,
        processingContext: fixture.context)
    }
    let state = try #require(try fixture.processingStore.read(rootID: fixture.context.rootID))
    let result = try #require(state.folders.first)
    #expect(result.matchedMovieID == .none)
    #expect(result.movieIdentitySource == .none)
    #expect(result.processingReason != .manualMatchingRequired)
    #expect(await provider.posterCount == 0)
  }

  /// Over-budget re-identification persists a manual choice without spending any alias or artwork request.
  @Test func refreshOverBudgetPersistsManualMatchingRequired() async throws {
    let fixture = try CollectionProcessingFixture(names: ["Movie (2021)"])
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let candidate = try FileSystemService().readCurrentFolderCandidate(ofChild: "Movie (2021)", in: fixture.root)
    let movies = (1...6).map {
      MovieMetadata(id: $0, title: "Other \($0)", originalTitle: "Other \($0)", releaseYear: 2021,
        posterPath: "/poster.jpg")
    }
    let provider = CountingProvider(search: MovieSearchResult(movies: movies, hasMorePages: false))
    let processor = fixture.processor(provider: provider)
    await #expect(throws: PosterActionError.unresolved) {
      try await processor.refreshPoster(root: fixture.root, child: candidate.name, expectedIdentity: candidate.identity,
        processingContext: fixture.context)
    }
    #expect(await provider.alternativeTitleCount == 0)
    #expect(await provider.posterCount == 0)
    let access = try #require(try fixture.processing.acquireAccess(for:
      MovieFolderProcessor.processingStateKey(for: fixture.root)))
    let saved = try await processor.loadState(from: access).folders[candidate.name]
    #expect(saved?.processingReason == .manualMatchingRequired)
    let state = try #require(try fixture.processingStore.read(rootID: fixture.context.rootID))
    let result = try #require(state.folders.first)
    #expect(result.processingState == .unresolved)
    #expect(result.processingReason == .manualMatchingRequired)
    #expect(result.matchedMovieID == .none)
  }

}

/// Local collection and current configuration required by the result change fence.
struct CollectionProcessingFixture {
  /// Root directory holding all disposable test inputs and records.
  let base: URL
  /// Collection containing only test-created child folders.
  let root: URL
  /// Persisted processing context.
  let context: CollectionProcessingContext
  /// Authoritative processing store under test.
  let processingStore: CollectionProcessingStore
  /// Existing processing decision store.
  let processing: PersistenceStore
  /// Cross-generation collection coordination store.
  let coordination: PersistenceStore
  /// Settings repository shared with the authoritative result store.
  let configuration: ConfigurationRepository
  /// Creates a disposable configured collection with the requested immediate-child directories.
  ///
  /// - Parameter names: Child folder names to create in the test collection.
  /// - Throws: Filesystem setup, identity lookup, or persistence errors.
  init(names: [String], matchingConfiguration: MovieMatchingConfiguration = MovieMatchingConfiguration()) throws {
    base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    root = base.appendingPathComponent("Movies")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for name in names {
      try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false)
    }
    configuration = ConfigurationRepository(
      store: try PersistenceStore(directory: base.appendingPathComponent("Settings")))
    let identity = try FileSystemService().persistentDirectoryIdentity(at: root)
    let directory = MonitoredDirectory(
      id: UUID(), path: root.path, transferBookmark: Data([1]), authorizationVersion: UUID(), identity: identity)
    try configuration.update {
      $0.directories = [directory]
      $0.movieMatchingConfiguration = matchingConfiguration
    }
    let settings = try configuration.read()
    context = CollectionProcessingContext(
      rootID: directory.id, rootIdentity: identity, authorizationVersion: directory.authorizationVersion,
      credentialRevision: settings.credentialRevision, usesStubTMDbResponses: false, appearance: .softFinish,
      movieMatchingConfiguration: settings.effectiveMovieMatchingConfiguration(for: directory),
      processingConfigurationRevision: directory.processingConfiguration.revision)
    processingStore = CollectionProcessingStore(
      store: try PersistenceStore(
        directory: base.appendingPathComponent("Outcomes"), maximumRecordBytes: 8 * 1024 * 1024),
      configuration: configuration)
    processing = try PersistenceStore(directory: base.appendingPathComponent("Processing"))
    coordination = try PersistenceStore(directory: base.appendingPathComponent("Locks"))
  }

  /// Creates the real processing pipeline with a controlled metadata source.
  func processor(provider: any MovieMetadataProvider) -> MovieFolderProcessor {
    MovieFolderProcessor(
      persistence: processing, provider: provider, cacheDirectory: base.appendingPathComponent("Posters"),
      processingLockStore: coordination, processingStore: processingStore,
      credentialRevision: context.credentialRevision,
      movieMatchingConfiguration: context.movieMatchingConfiguration)
  }
}

/// Finite deterministic provider responses without credentials, remote requests, or poster writes.
private struct CollectionProcessingMetadataProvider: MovieMetadataProvider {
  /// Whether every search should produce an authentication backoff.
  var authenticationFailure = false
  /// Optional real fixture artwork for manual assignment verification.
  var posterData: Data?
  /// Whether the identified movie's image request should simulate an offline transport.
  var shouldFailPoster = false
  /// Whether the unique movie identity lacks provider artwork.
  var missingArtwork = false

  /// Returns the configured offline search scenario, including incomplete or ambiguous results.
  /// Supplies completed empty alternative-title evidence for this focused fixture.
  /// Supplies completed release events for this provider.
  func releaseDates(movieID: Int) throws -> MovieReleaseDatesByID { [movieID: []] }
  func alternativeTitles(movieID: Int) throws -> MovieAlternativeTitlesByID { [movieID: []] }

  func searchMovies(title: String, year: Int?, language: TMDbLanguage = .english) throws -> MovieSearchResult {
    if authenticationFailure { throw TMDbError.authentication }
    if missingArtwork {
      return MovieSearchResult(
        movies: [
          MovieMetadata(id: 7, title: title, originalTitle: title, releaseYear: year ?? 2021, posterPath: .none)
        ], hasMorePages: false)
    }
    if posterData != .none {
      return MovieSearchResult(
        movies: [
          MovieMetadata(id: 7, title: title, originalTitle: title, releaseYear: year ?? 2021, posterPath: "/chosen.jpg")
        ], hasMorePages: false)
    }
    if title == "Ambiguous" {
      return MovieSearchResult(
        movies: [
          MovieMetadata(id: 1, title: title, originalTitle: title, releaseYear: year ?? 2021, posterPath: "/one.jpg"),
          MovieMetadata(id: 2, title: title, originalTitle: title, releaseYear: year ?? 2021, posterPath: "/two.jpg")
        ], hasMorePages: false)
    }

    return MovieSearchResult(movies: [], hasMorePages: title == "Incomplete")
  }

  /// Returns fixture artwork or the configured transport or missing-artwork failure.
  func downloadPoster(path: String) throws -> Data {
    if shouldFailPoster { throw TMDbError.transport(code: -1009) }
    guard let posterData else { throw TMDbError.invalidPosterPath }

    return posterData
  }
}

/// Injects an operational storage failure after the real native icon adapter completes its write.
private struct CacheFailurePosterAssigner: PosterAssigner {
  /// Only the disposable test processing-store directory is modified.
  let directory: URL

  /// Assigns the real test icon, then corrupts only test outcome records to simulate a later cache failure.
  func assignPoster(
    _ imageData: Data, toChild name: String, in root: URL, expectedIdentity: String?
  ) throws -> FolderPosterAssignmentResult {
    let result = try FileSystemService().assignPoster(
      imageData, toChild: name, in: root, expectedIdentity: expectedIdentity)
    let records = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: .none)
      .filter { $0.pathExtension == "json" }
    for record in records { try Data("broken envelope".utf8).write(to: record) }

    return result
  }
}

/// Permits inspection while rejecting the manual change guard used by automatic restyling.
private struct RefusingRestyleVerifier: MovieFolderProcessingVerifier {
  /// Permits automatic change to reach the manual restyle guard under test.
  func checkAutomaticProcessing(in root: URL) throws -> PersistenceAccess? { .none }

  /// Rejects restyling with the configured icon-assignment failure.
  func checkIconChange(
    _ change: MovieFolderIconChange, to candidate: MovieFolderCandidate, in root: URL
  ) throws -> PersistenceAccess? {
    throw FolderPosterError.iconAssignmentFailed
  }
}

/// A cancellable provider suspension coordinated through actor messages rather than timed test polling.
private actor BlockingCollectionProcessingMetadataProvider: MovieMetadataProvider {
  /// Whether the real processor has entered provider work.
  private var started = false
  /// One test awaiting the processing boundary.
  private var waiter: CheckedContinuation<Void, Never>?

  /// Suspends the test until the provider has entered its cancellable search.
  func waitForSearch() async {
    if started { return }
    await withCheckedContinuation { waiter = $0 }
  }

  /// Signals search entry and suspends long enough for the test to cancel processing.
  /// Supplies completed empty alternative-title evidence for this focused fixture.
  /// Supplies completed release events for this provider.
  func releaseDates(movieID: Int) throws -> MovieReleaseDatesByID { [movieID: []] }
  func alternativeTitles(movieID: Int) throws -> MovieAlternativeTitlesByID { [movieID: []] }

  func searchMovies(title: String, year: Int?, language: TMDbLanguage = .english) async throws -> MovieSearchResult {
    started = true
    waiter?.resume()
    waiter = .none
    try await Task.sleep(for: .seconds(60))

    return MovieSearchResult(movies: [], hasMorePages: false)
  }

  /// Rejects artwork requests because this provider exists only to exercise search cancellation.
  /// - Parameter path: Unused provider artwork path.
  /// - Throws: `TMDbError.invalidPosterPath` for every request.
  func downloadPoster(path: String) throws -> Data { throw TMDbError.invalidPosterPath }
}

/// Covers artwork outcomes without increasing the collection-state integration suite size.
struct CollectionProcessingArtworkIntegrationTests {
  /// Identity remains available when the conservatively identified movie has no artwork.
  @Test func missingArtworkIsNotMissingMovieIdentity() async throws {
    let fixture = try CollectionProcessingFixture(names: ["Movie (2021)"])
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    _ = try await fixture.processor(provider: CollectionProcessingMetadataProvider(missingArtwork: true)).process(
      root: fixture.root, processingContext: fixture.context)
    let processingState = try #require(try fixture.processingStore.read(rootID: fixture.context.rootID))
    #expect(processingState.folders.first?.processingState == .unresolved)
    #expect(processingState.folders.first?.processingReason == .missingArtwork)
    #expect(processingState.folders.first?.matchedMovieID == 7)
    #expect(processingState.folders.first?.movieIdentitySource == .conservativeMatch)
    #expect(processingState.calculateCounts().notFound == 0)
  }

  /// A poster transport failure retains established movie identity and is not a metadata failure.
  @Test func artworkFailureKeepsIdentifiedMovie() async throws {
    let fixture = try CollectionProcessingFixture(names: ["Movie (2021)"])
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let provider = CollectionProcessingMetadataProvider(posterData: Data([1]), shouldFailPoster: true)
    let summary = try await fixture.processor(provider: provider).process(
      root: fixture.root, processingContext: fixture.context)
    let processingState = try #require(try fixture.processingStore.read(rootID: fixture.context.rootID))
    let record = try #require(processingState.folders.first)
    #expect(record.processingState == .failed)
    #expect(record.processingReason == .connectivity)
    #expect(record.lastFailure?.reason == .connectivity)
    #expect(record.lastFailure?.stage == .artwork)
    #expect(record.matchedMovieID == 7)
    #expect(record.matchedMovieTitle == "Movie")
    #expect(summary.nextAutomaticRetryAt == record.nextRetryAt)
    #expect(processingState.calculateCounts().notFound == 0)
  }

  /// A failed restyle leaves the existing verified poster Done and records the failed attempt separately.
  @Test func automaticRestyleFailureRetainsVerifiedInstalledPoster() async throws {
    let fixture = try CollectionProcessingFixture(names: ["Movie (2021)"])
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    #if SWIFT_PACKAGE
      let image = try #require(Bundle.module.url(forResource: "TestPoster", withExtension: "png"))
    #else
      let image = try #require(
        Bundle(for: MoviePosterActionTests.self).url(forResource: "TestPoster", withExtension: "png"))
    #endif
    let movie = MovieMetadata(
      id: 7, title: "Chosen", originalTitle: "Chosen", releaseYear: 2021, posterPath: "/chosen.jpg")
    let identity = try FileSystemService().readCurrentFolderCandidate(ofChild: "Movie (2021)", in: fixture.root).identity
    let provider = CollectionProcessingMetadataProvider(posterData: try Data(contentsOf: image))
    _ = try await fixture.processor(provider: provider)
      .applyMoviePoster(
        movie, root: fixture.root, child: "Movie (2021)", expectedIdentity: identity,
        processingContext: fixture.context)
    let configuration = ConfigurationRepository(
      store: try PersistenceStore(directory: fixture.base.appendingPathComponent("Settings")))
    try configuration.update { $0.posterAppearance = .raw }
    let context = CollectionProcessingContext(
      rootID: fixture.context.rootID, rootIdentity: fixture.context.rootIdentity,
      authorizationVersion: fixture.context.authorizationVersion,
      credentialRevision: fixture.context.credentialRevision,
      usesStubTMDbResponses: false, appearance: .raw,
      processingConfigurationRevision: fixture.context.processingConfigurationRevision)
    let activity = ProcessingActivityProbe()
    let directory = try #require(try configuration.read().directories.first)
    let processor = MovieFolderProcessor(
      persistence: fixture.processing, provider: CollectionProcessingMetadataProvider(),
      cacheDirectory: fixture.base.appendingPathComponent("Posters"), processingLockStore: fixture.coordination,
      processingVerifier: RefusingRestyleVerifier(), appearance: .raw, processingStore: fixture.processingStore,
      activityHistoryService: activity, activityLogContext: MovieFolderActivityLogContext(directory: directory))
    _ = try await processor.process(root: fixture.root, processingContext: context)
    let processingState = try #require(try fixture.processingStore.read(rootID: context.rootID))
    #expect(processingState.folders.first?.processingState == .done)
    #expect(processingState.folders.first?.lastFailure?.stage == .assignPoster)
    let failure = try #require(await activity.events.first { $0.folderResult == .failed })
    #expect(failure.target?.movieID == 7)
    #expect(failure.target?.movieTitle == "Chosen")
    #expect(failure.failure?.stage == .assignPoster)
    #expect(failure.failure?.reason == .filesystem)
    #expect(try FileSystemService().assignedPosterAppearance(toChild: "Movie (2021)", in: fixture.root) == .softFinish)
  }

}
