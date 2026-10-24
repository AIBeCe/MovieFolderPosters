import FileSystem
import Foundation
import Network
import Persistence
import Testing

@testable import MovieFolderCommon

/// Checks durable results through the production processor and real local stores.
struct CollectionProcessingIntegrationTests {
  /// Identity remains available when the conservatively identified movie has no artwork.
  @Test func missingArtworkIsNotMissingMovieIdentity() async throws {
    let fixture = try CollectionProcessingFixture(names: ["Movie (2021)"])
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    _ = try await fixture.processor(provider: CollectionProcessingMetadataProvider(missingArtwork: true)).process(
      root: fixture.root, processingContext: fixture.context)
    let processingState = try #require(try fixture.processingStore.read(rootID: fixture.context.rootID))
    #expect(processingState.folders.first?.state == .unresolved)
    #expect(processingState.folders.first?.reason == .missingArtwork)
    #expect(processingState.folders.first?.movieID == 7)
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
    #expect(record.state == .failed)
    #expect(record.reason == .connectivity)
    #expect(record.lastFailure?.reason == .connectivity)
    #expect(record.lastFailure?.stage == .artwork)
    #expect(record.movieID == 7)
    #expect(record.movieTitle == "Movie")
    #expect(summary.nextAutomaticRetryAt == record.retryAt)
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
    let identity = try FileSystemService().readCurrentState(ofChild: "Movie (2021)", in: fixture.root).identity
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
    let processor = MovieFolderProcessor(
      persistence: fixture.processing, provider: CollectionProcessingMetadataProvider(),
      cacheDirectory: fixture.base.appendingPathComponent("Posters"), coordinationStore: fixture.coordination,
      processingVerifier: RefusingRestyleVerifier(), appearance: .raw, processingStore: fixture.processingStore)
    _ = try await processor.process(root: fixture.root, processingContext: context)
    let processingState = try #require(try fixture.processingStore.read(rootID: context.rootID))
    #expect(processingState.folders.first?.state == .done)
    #expect(processingState.folders.first?.lastFailure?.stage == .assignPoster)
    #expect(try FileSystemService().assignedPosterAppearance(toChild: "Movie (2021)", in: fixture.root) == .softFinish)
  }

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
      coordinationStore: fixture.coordination, processingStore: fixture.processingStore)
    do {
      _ = try await processor.process(root: fixture.root, processingContext: fixture.context)
      Issue.record("A broken processing cache must stop this attempt")
    } catch CollectionProcessingError.unavailable {}
    let processingState = try #require(try fixture.processingStore.read(rootID: fixture.context.rootID))
    let alpha = try #require(processingState.folders.first { $0.name == "Alpha (2021)" })
    #expect(alpha.state == .done)
    #expect(alpha.reason == .cachePersistenceFailure)
    #expect(alpha.lastFailure?.stage == .persist)
    #expect(processingState.currentRun?.state == .failed)
    #expect(try FileSystemService().hasAssignedPoster(toChild: "Alpha (2021)", in: fixture.root))
    #expect(try !FileSystemService().readCurrentState(ofChild: "Beta (2021)", in: fixture.root).hasCustomIcon)
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
    let identity = try FileSystemService().readCurrentState(ofChild: "Missing (2021)", in: fixture.root).identity
    let movie = MovieMetadata(
      id: 7, title: "Chosen", originalTitle: "Chosen", releaseYear: 2021, posterPath: "/chosen.jpg")
    _ = try await processor.applyMoviePoster(
      movie, root: fixture.root, child: "Missing (2021)", expectedIdentity: identity,
      processingContext: fixture.context)
    let selected = try #require(try fixture.processingStore.read(rootID: fixture.context.rootID))
    #expect(selected.folders.first?.state == .done)
    #expect(selected.folders.first?.movieID == 7)
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
    #expect(failedRefresh.folders.first?.state == .done)
    #expect(failedRefresh.folders.first?.lastFailure != .none)
    #expect(failedRefresh.currentRun?.state == .failed)

    _ = try await processor.removePoster(
      root: fixture.root, child: "Missing (2021)", expectedIdentity: identity, processingContext: fixture.context)
    let removed = try #require(try fixture.processingStore.read(rootID: fixture.context.rootID))
    #expect(removed.folders.first?.state == .suppressed)
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
    #expect(running.currentRun?.state == .running)
    #expect(running.calculateCounts().total == 1)
    #expect(running.calculateCounts().notFound == .none)
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Cancellation must propagate")
    } catch is CancellationError {}
    let interrupted = try #require(try fixture.processingStore.read(rootID: fixture.context.rootID))
    #expect(interrupted.currentRun?.state == .interrupted)
    #expect(interrupted.folders.first?.state == .uncertain)
    #expect(interrupted.lastCompletedRun == .none)
  }

  /// Complete negative and ambiguous searches remain distinguishable after reopening storage.
  @Test func distinctMatchingResultsSurviveReopening() async throws {
    let fixture = try CollectionProcessingFixture(names: ["Missing (2021)", "Ambiguous (2021)", "Incomplete (2021)"])
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let processor = fixture.processor(provider: CollectionProcessingMetadataProvider())
    let summary = try await processor.process(root: fixture.root, processingContext: fixture.context)
    let processingState = try #require(try fixture.processingStore.read(rootID: fixture.context.rootID))
    let records = Dictionary(uniqueKeysWithValues: processingState.folders.map { ($0.name, $0) })
    #expect(records["Missing (2021)"]?.state == .notFound)
    #expect(records["Ambiguous (2021)"]?.state == .severalMatches)
    #expect(records["Incomplete (2021)"]?.reason == .incompleteSearch)
    #expect(summary.nextAutomaticRetryAt == records["Incomplete (2021)"]?.retryAt)
    #expect(processingState.calculateCounts().total == 3)
    #expect(processingState.calculateCounts().notFound == 1)
    #expect(processingState.calculateCounts().severalMatches == 1)
    #expect(processingState.currentRun?.state == .completed)
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
    #expect(processingState.lastCompletedRun?.state == .completed)
  }

  /// Authentication backoff stops the traversal without inventing processingStore for unvisited folders.
  @Test func providerBackoffPersistsPartialTraversal() async throws {
    let fixture = try CollectionProcessingFixture(names: ["First (2021)", "Second (2021)"])
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let provider = CollectionProcessingMetadataProvider(authenticationFailure: true)
    _ = try await fixture.processor(provider: provider).process(
      root: fixture.root, processingContext: fixture.context)
    let processingState = try #require(try fixture.processingStore.read(rootID: fixture.context.rootID))
    #expect(processingState.currentRun?.state == .partial)
    #expect(processingState.lastCompletedRun == .none)
    #expect(processingState.folders.contains { $0.state == .pending || $0.state == .deferred })
    #expect(processingState.folders.contains { $0.reason == .authentication })
  }

  /// Neither a new authentication failure nor cached rejection can fabricate a completed collection run.
  @Test(arguments: [false, true])
  func authenticationAdmissionPreservesPartialTraversal(cachedRejection: Bool) async throws {
    let fixture = try CollectionProcessingFixture(names: ["First (2021)", "Second (2021)"])
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let recovery = ProcessingRecoveryService(
      store: try PersistenceStore(directory: fixture.base.appendingPathComponent("Recovery")))
    let provider = RecoveryMovieMetadataProvider(
      provider: CollectionProcessingMetadataProvider(authenticationFailure: true),
      recovery: recovery, credential: "token")
    if cachedRejection {
      await #expect(throws: TMDbError.authentication) { try await provider.searchMovies(title: "Warmup", year: .none) }
    }
    let processor = MovieFolderProcessor(
      persistence: fixture.processing, provider: provider,
      cacheDirectory: fixture.base.appendingPathComponent("Posters"),
      coordinationStore: fixture.coordination, processingStore: fixture.processingStore, recovery: recovery)

    _ = try await processor.process(root: fixture.root, processingContext: fixture.context)

    let state = try #require(try fixture.processingStore.read(rootID: fixture.context.rootID))
    #expect(state.currentRun?.state == .partial)
    #expect(state.lastCompletedRun == .none)
    #expect(state.folders.contains { $0.state == .pending })
    #expect(state.folders.contains { $0.reason == .authentication })
  }
}

/// Local collection and current configuration required by the result change fence.
private struct CollectionProcessingFixture {
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

  /// Creates a disposable configured collection with the requested immediate-child directories.
  ///
  /// - Parameter names: Child folder names to create in the test collection.
  /// - Throws: Filesystem setup, identity lookup, or persistence errors.
  init(names: [String]) throws {
    base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    root = base.appendingPathComponent("Movies")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for name in names {
      try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false)
    }
    let configuration = ConfigurationRepository(
      store: try PersistenceStore(directory: base.appendingPathComponent("Settings")))
    let identity = try FileSystemService().persistentDirectoryIdentity(at: root)
    let directory = MonitoredDirectory(
      id: UUID(), path: root.path, transferBookmark: Data([1]), authorizationVersion: UUID(), identity: identity)
    try configuration.update { $0.directories = [directory] }
    let settings = try configuration.read()
    context = CollectionProcessingContext(
      rootID: directory.id, rootIdentity: identity, authorizationVersion: directory.authorizationVersion,
      credentialRevision: settings.credentialRevision, usesStubTMDbResponses: false, appearance: .softFinish,
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
      coordinationStore: coordination, processingStore: processingStore)
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
  func searchMovies(title: String, year: Int?) throws -> MovieSearchResult {
    if authenticationFailure { throw TMDbError.authentication }
    if missingArtwork {
      return MovieSearchResult(
        movies: [
          MovieMetadata(id: 7, title: title, originalTitle: title, releaseYear: year, posterPath: .none)
        ], hasMorePages: false)
    }
    if posterData != .none {
      return MovieSearchResult(
        movies: [
          MovieMetadata(id: 7, title: title, originalTitle: title, releaseYear: year, posterPath: "/chosen.jpg")
        ], hasMorePages: false)
    }
    if title == "Ambiguous" {
      return MovieSearchResult(
        movies: [
          MovieMetadata(id: 1, title: title, originalTitle: title, releaseYear: year, posterPath: "/one.jpg"),
          MovieMetadata(id: 2, title: title, originalTitle: title, releaseYear: year, posterPath: "/two.jpg")
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
  ) throws -> PosterAssignmentResult {
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
  func checkIconChange(_ change: MovieFolderIconChange, to candidate: FolderCandidate, in root: URL) throws -> PersistenceAccess? {
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
  func searchMovies(title: String, year: Int?) async throws -> MovieSearchResult {
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
