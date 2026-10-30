import AppKit
import FileSystem
import Foundation
import MovieFolderCommon
import Network
import Persistence
import Testing

@testable import MovieFolderPosters

/// Exercises authorization and real processing using only disposable stores and folders.
struct MoviePosterActionServiceTests {
  /// Explicit movie search forwards the saved regional language through the authorized action service.
  @Test func movieSelectionSearchUsesSavedLanguage() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let language = try TMDbLanguage("pt-BR")
    try fixture.repository.update { $0.movieMatchingConfiguration.searchLanguage = language }
    let provider = ActionProvider(changesDuringDownload: true)
    let result = try await fixture.service(movieMetadataProvider: provider).searchMovies(
      for: fixture.request, query: "Dune", year: 2021, language: language)

    #expect(result.movies.first?.title == "Dune")
    #expect(await provider.searchLanguages == ["pt-BR"])
  }

  /// Actual user-requested actions identify their authorized collection and immediate child folder.
  @Test func activityIdentifiesTheCollectionFolderAndMovie() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let activityHistoryService = ActivityServiceFake()
    let movie = MovieMetadata(id: 7, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
      posterPath: "/chosen.png")
    _ = try await fixture.service(activity: activityHistoryService).applyPoster(movie, for: fixture.request)
    let recordedMessages = try await activityHistoryService.entries().map { $0.event.text }

    #expect(recordedMessages.contains { $0.contains("Movies") && $0.contains("Dune (2021)") })
    #expect(recordedMessages.contains { $0.contains("Confirmed movie: “Dune” (2021)") })
    #expect(try await activityHistoryService.entries().contains { $0.event.target?.movieID == 7 })
  }

  /// An action without verified collection capture must not retain correlation or collection identifiers.
  @Test func missingCollectionContextRecordsOnlyUnlinkedActivity() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let activityHistoryService = ActivityServiceFake()
    let request = MoviePosterRequest(rootID: UUID(), childName: fixture.request.childName,
      identity: fixture.request.identity, action: .refresh)
    await #expect(throws: MoviePosterActionServiceError.directoryNotConfigured) {
      try await fixture.service(activity: activityHistoryService).refreshPoster(for: request)
    }
    let events = try await activityHistoryService.entries().map(\.event)

    #expect(events.map(\.status) == [.started, .failed])
    #expect(events.allSatisfy { $0.target == .none && $0.collectionID == .none && $0.activityGroupID == .none })
  }

  /// Pausing collection inclusion still permits explicit owned-poster removal and retains suppression.
  @Test func pausedCollectionAllowsExplicitRemoval() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let service = fixture.service()
    let movie = MovieMetadata(id: 7, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
      posterPath: "/chosen.png")
    _ = try await service.applyPoster(movie, for: fixture.request)
    try fixture.repository.update { configuration in
      _ = configuration.directories[0].processingConfiguration.setPaused(true)
    }

    #expect(try await service.removePoster(for: fixture.request))
    #expect(try FileSystemService().isPosterSuppressed(toChild: fixture.request.childName, in: fixture.movies))
    #expect(try !FileSystemService().readCurrentState(ofChild: fixture.request.childName, in: fixture.movies)
      .hasCustomIcon)
  }

  /// Cancelling a noncooperative provider retains admission until its service call returns.
  @Test(.timeLimit(.minutes(1))) func cancelledSearchRetainsSharedAdmissionUntilItReturns() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let movieMetadataProvider = SuspendedActionProvider()
    let service = fixture.service(movieMetadataProvider: movieMetadataProvider)
    let search = Task { try await service.searchMovies(for: fixture.request, query: "Dune", year: 2021) }
    await movieMetadataProvider.waitForSearch()
    search.cancel()
    await #expect(throws: PosterActionError.busy) { try await service.matchedMovieID(for: fixture.request) }
    await #expect(throws: PosterActionError.busy) { try await service.retryFolder(for: fixture.request) }
    await movieMetadataProvider.finishSearch()
    await #expect(throws: CancellationError.self) { try await search.value }
    #expect(try await service.matchedMovieID(for: fixture.request) == .none)
  }

  /// Explicit selection and selected retry retain unrelated evidence and update authoritative counts.
  /// - Parameter choosesMovie: Whether the user resolves a confirmed negative result by explicit selection.
  @Test(arguments: [false, true])
  func selectedActionsUpdateOnlyTheirRequestedFolder(choosesMovie: Bool) async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let configuration = try fixture.repository.read()
    let root = try #require(configuration.directories.first)
    let rootIdentity = try #require(root.identity)
    let context = CollectionProcessingContext(
      rootID: root.id, rootIdentity: rootIdentity, authorizationVersion: root.authorizationVersion,
      credentialRevision: configuration.credentialRevision,
      usesStubTMDbResponses: configuration.usesStubTMDbResponses, appearance: configuration.posterAppearance,
      processingConfigurationRevision: root.processingConfiguration.revision)
    let unrelated = FolderProcessingRecord(
      name: "Unrelated", identity: "untouched", state: .notFound, reason: .noSuitableMovie)
    var initial = try fixture.processing.recordProcessingStart(context: context, action: .automatic)
    initial.folders = [
      FolderProcessingRecord(name: fixture.request.childName, identity: fixture.request.identity,
        state: choosesMovie ? .notFound : .failed, reason: choosesMovie ? .noSuitableMovie : .connectivity),
      unrelated
    ]
    initial.isInventoryComplete = true
    initial.inspectedAt = Date()
    initial.currentRun?.state = .partial
    _ = try fixture.processing.commit(initial, expectedRevision: initial.revision)
    let movieMetadataProvider = ActionProvider()
    let service = fixture.service(movieMetadataProvider: movieMetadataProvider)
    if choosesMovie {
      let movie = MovieMetadata(id: 7, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
        posterPath: "/chosen.png")
      #expect(try await service.applyPoster(movie, for: fixture.request) == 7)
      #expect(await movieMetadataProvider.searches.isEmpty)
    } else {
      let result = try await service.retryFolder(for: fixture.request)
      guard case .attempted(let summary, let stopSelection) = result else {
        Issue.record("Eligible selected work must be attempted")
        return
      }
      #expect(summary.assigned == 1)
      #expect(!stopSelection)
    }
    let saved = try #require(try fixture.processing.read(rootID: root.id))
    #expect(saved.folders.first { $0.name == fixture.request.childName }?.isVerifiedDone == true)
    #expect(saved.folders.first { $0.name == unrelated.name } == unrelated)
    #expect(saved.calculateCounts().done == 1)
    #expect(saved.calculateCounts().notFound == 1)
    #expect(saved.calculateCounts().total == 2)
  }

  /// Candidate results cannot be returned for a child replaced while the search was suspended.
  @Test(.timeLimit(.minutes(1))) func searchRevalidatesChildAfterProviderReturns() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let movieMetadataProvider = SuspendedActionProvider()
    let service = fixture.service(movieMetadataProvider: movieMetadataProvider)
    let search = Task { try await service.searchMovies(for: fixture.request, query: "Dune", year: 2021) }
    await movieMetadataProvider.waitForSearch()
    let child = fixture.movies.appendingPathComponent(fixture.request.childName)
    try FileManager.default.moveItem(at: child, to: fixture.movies.appendingPathComponent("Previous"))
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
    await movieMetadataProvider.finishSearch()
    await #expect(throws: MoviePosterActionServiceError.childChanged) { try await search.value }
  }

  /// A previously composed host service rechecks durable admission before direct manual searches.
  @Test func cachedManualServiceHonorsRecoveryModeAndExplicitResume() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let movieMetadataProvider = ActionProvider()
    let service = fixture.service(movieMetadataProvider: movieMetadataProvider)
    let recovery = try fixture.makeProcessingRecoveryService()
    try recovery.setRecoveryModeEnabled(true)
    await #expect(throws: ProcessingRecoveryError.recoveryMode) {
      try await service.searchMovies(for: fixture.request, query: "Dune", year: .none)
    }
    #expect(await movieMetadataProvider.searches.isEmpty)
    await #expect(throws: ProcessingRecoveryError.recoveryMode) {
      try await service.removePoster(for: fixture.request)
    }
    try recovery.setRecoveryModeEnabled(false)
    #expect(await movieMetadataProvider.searches.isEmpty)
    _ = try await service.searchMovies(for: fixture.request, query: "Dune", year: .none)
    #expect(await movieMetadataProvider.searches == ["Dune:none"])
  }

  /// An authorized empty assignment must remain readable without a credential.
  @Test func readsUnassignedFolderWithoutCredential() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let service = MoviePosterActionService(
      credentials: ActionCredentials(token: .none), activity: ActivityServiceFake(), environment: fixture)
    #expect(try await service.matchedMovieID(for: fixture.request) == .none)
  }

  /// Rejects malformed searches before configuration or credentials can be consulted.
  @Test(arguments: ["", "  ", "Dune\nArrival", "Dune\rArrival"])
  func rejectsInvalidQuery(_ query: String) async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let service = fixture.service()
    await #expect(throws: MoviePosterActionServiceError.invalidQuery) {
      try await service.searchMovies(for: fixture.request, query: query, year: .none)
    }
  }

  /// Rejects unsupported years instead of silently broadening the user's search.
  @Test(arguments: [1887, 2100])
  func rejectsInvalidYear(_ year: Int) async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    await #expect(throws: MoviePosterActionServiceError.invalidQuery) {
      try await fixture.service().searchMovies(for: fixture.request, query: "Dune", year: year)
    }
  }

  /// Missing or replaced children and removed roots cannot authorize an old Finder request.
  @Test(arguments: ["removedRoot", "missingChild", "replacedIdentity", "wrongPath", "overlap"])
  func rejectsStaleFolderAuthorization(_ scenario: String) async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    var request = fixture.request
    let expected: MoviePosterActionServiceError
    switch scenario {
    case "removedRoot":
      try fixture.repository.update { $0.directories = [] }
      expected = .directoryNotConfigured
    case "missingChild":
      try FileManager.default.removeItem(at: fixture.movies.appendingPathComponent(request.childName))
      expected = .childChanged
    case "replacedIdentity":
      request = MoviePosterRequest(rootID: request.rootID, childName: request.childName,
        identity: "obsolete", action: .change)
      expected = .childChanged
    case "wrongPath":
      try fixture.repository.update { $0.directories[0].path += "/Elsewhere" }
      expected = .directoryUnavailable
    default:
      try fixture.repository.update { configuration in
        let existing = configuration.directories[0]
        let nested = MonitoredDirectory(id: UUID(), path: existing.path + "/Nested",
          transferBookmark: existing.transferBookmark, authorizationVersion: UUID(), identity: existing.identity)
        configuration.directories.append(nested)
      }
      expected = .directoryUnavailable
    }
    await #expect(throws: expected) { try await fixture.service().matchedMovieID(for: request) }
  }

  /// A concurrent authorization access denies entry rather than running without coordination.
  @Test func authorizationContentionPreventsRead() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let directory = try #require(try fixture.repository.read().directories.first)
    let persistenceAccess = try #require(try fixture.authorizations.acquireAccess(
      for: "host-\(directory.id)-\(directory.authorizationVersion)"))
    await #expect { try await fixture.service().matchedMovieID(for: fixture.request) } throws: { error in
      if case ConfigurationError.busy = error { return true }

      return false
    }
    withExtendedLifetime(persistenceAccess) {}
  }

  /// Credentials remain mandatory even when the network provider is injected.
  @Test func missingCredentialPreventsSearch() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let service = fixture.service(token: .none)
    await #expect(throws: MoviePosterActionServiceError.credentialUnavailable) {
      try await service.searchMovies(for: fixture.request, query: "Dune", year: .none)
    }
  }

  /// Injected providers cannot bypass validation of malformed nonempty credentials.
  @Test func malformedCredentialPreventsProviderSearch() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let movieMetadataProvider = ActionProvider()
    await #expect(throws: TMDbError.self) {
      try await fixture.service(token: "invalid\ntoken", movieMetadataProvider: movieMetadataProvider).searchMovies(
        for: fixture.request, query: "Dune", year: .none)
    }
    #expect(await movieMetadataProvider.searches.isEmpty)
  }

  /// Selected IDs and artwork are validated before any authorization or change occurs.
  @Test(arguments: [Int.zero, -1, 7])
  func invalidSelectionRecordsFailure(_ identifier: Int) async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let activity = ActivityServiceFake()
    let movie = MovieMetadata(id: identifier, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
      posterPath: identifier == 7 ? "  " : "/poster.png")
    let service = fixture.service(activity: activity)
    await #expect(throws: MoviePosterActionServiceError.invalidSelection) {
      try await service.applyPoster(movie, for: fixture.request)
    }
    let events = try await activity.entries().map(\.event)
    #expect(events.map(\.status) == [.started, .failed])
    #expect(events.first?.activityGroupID == events.last?.activityGroupID)
    #expect(events.last?.failure?.reason == .invalidSelection)
    #expect(events.last?.text.contains("Dune (2021)") == true)
    #expect(try FileSystemService().readCurrentState(ofChild: fixture.request.childName, in: fixture.movies)
      .hasCustomIcon == false)
  }

  /// Selection persists the chosen identity, refresh retains it, and removal clears the owned icon.
  @Test func selectionRefreshAndRemovalUseRealProcessing() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let movieMetadataProvider = ActionProvider()
    let activity = ActivityServiceFake()
    let service = fixture.service(movieMetadataProvider: movieMetadataProvider, activity: activity)
    let movie = MovieMetadata(id: 7, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
      posterPath: "/chosen.png")
    #expect(try await service.applyPoster(movie, for: fixture.request) == 7)
    #expect(try await service.matchedMovieID(for: fixture.request) == 7)
    #expect(try await service.refreshPoster(for: fixture.request) == 7)
    #expect(try await service.removePoster(for: fixture.request))
    #expect(try await service.removePoster(for: fixture.request) == false)
    #expect(try await service.matchedMovieID(for: fixture.request) == .none)
    #expect(await movieMetadataProvider.downloads == ["/chosen.png", "/chosen.png"])
    #expect(await movieMetadataProvider.searches.isEmpty)
    let folderResults = try await activity.entries().compactMap(\.event.folderResult)
    #expect(folderResults.contains(.posterApplied))
    #expect(folderResults.contains(.posterRemoved))
    #expect(folderResults.contains(.noPosterToRemove))
    #expect(try await activity.entries().map(\.event).filter { $0.folderResult == .none }.map(\.status) == [
      .started, .succeeded, .started, .succeeded, .started, .succeeded, .started, .succeeded
    ])
  }

  /// Search trims user input and preserves the provider's pagination result.
  @Test func authorizedSearchPreservesQueryAndResults() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let movieMetadataProvider = ActionProvider()
    let result = try await fixture.service(movieMetadataProvider: movieMetadataProvider).searchMovies(
      for: fixture.request, query: "  Dune  ", year: 2021)
    #expect(result.movies.map(\.id) == [7])
    #expect(!result.hasMorePages)
    #expect(await movieMetadataProvider.searches == ["Dune:2021"])
  }

  /// Provider cancellation keeps a distinct cancelled event and leaves the folder untouched.
  @Test func cancelledRefreshRecordsCancellation() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let activity = ActivityServiceFake()
    let movieMetadataProvider = ActionProvider(cancels: true)
    await #expect(throws: CancellationError.self) {
      try await fixture.service(movieMetadataProvider: movieMetadataProvider, activity: activity)
        .refreshPoster(for: fixture.request)
    }
    #expect(try await activity.entries().map(\.event).filter { $0.folderResult == .none }.map(\.status)
      == [.started, .cancelled])
    #expect(try FileSystemService().readCurrentState(ofChild: fixture.request.childName, in: fixture.movies)
      .hasCustomIcon == false)
  }

}

/// Supplies private, real persistence and directory identity for an action.
private struct PosterActionFixture: MoviePosterActionEnvironment {
  /// Parent of every disposable file used by the test.
  let container: URL
  /// Configured movie root.
  let movies: URL
  /// Stored configuration used for authorization checks.
  let repository: ConfigurationRepository
  /// Private bookmark persistence.
  let authorizations: PersistenceStore
  /// Real processing outcome store.
  let processing: CollectionProcessingStore
  /// Request bound to the real child identity.
  let request: MoviePosterRequest

  /// Creates real stores and a child folder whose identity can authorize the request.
  init() throws {
    container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    movies = container.appendingPathComponent("Movies")
    try FileManager.default.createDirectory(
      at: movies.appendingPathComponent("Dune (2021)"), withIntermediateDirectories: true)
    repository = ConfigurationRepository(
      store: try PersistenceStore(directory: container.appendingPathComponent("Settings")))
    authorizations = try PersistenceStore(directory: container.appendingPathComponent("Authorization"))
    processing = CollectionProcessingStore(
      store: try PersistenceStore(directory: container.appendingPathComponent("Outcomes")), configuration: repository)
    let fileSystem = FileSystemService()
    let directory = MonitoredDirectory(
      id: UUID(), path: movies.standardizedFileURL.path,
      transferBookmark: try fileSystem.makeTransferBookmark(for: movies), authorizationVersion: UUID(),
      identity: try fileSystem.persistentDirectoryIdentity(at: movies))
    try repository.update { $0.directories = [directory] }
    request = MoviePosterRequest(rootID: directory.id, childName: "Dune (2021)",
      identity: try fileSystem.readCurrentState(ofChild: "Dune (2021)", in: movies).identity, action: .change)
  }

  func makeDirectoryBookmark(for directory: URL) throws -> Data {
    try directory.bookmarkData(options: [], includingResourceValuesForKeys: .none, relativeTo: .none)
  }
  func appGroupContainerURL() throws -> URL { container }
  func makeConfigurationRepository() throws -> ConfigurationRepository { repository }
  func makePrivateAuthorizationStore() throws -> PersistenceStore { authorizations }
  func makeCollectionProcessingStore() throws -> CollectionProcessingStore { processing }
  /// Composes the real action service without external storage, credentials, or networking.
  func service(token: String? = "fixture-token", movieMetadataProvider: (any MovieMetadataProvider)? = .none,
               activity: (any MovieFolderActivityServicing)? = .none) -> MoviePosterActionService {
    MoviePosterActionService(credentials: ActionCredentials(token: token), activity: activity ?? ActivityServiceFake(),
      environment: self, movieMetadataProvider: movieMetadataProvider ?? ActionProvider())
  }

  /// Removes all test-owned resources after leases and operations finish.
  func cleanup() { try? FileManager.default.removeItem(at: container) }
}

/// Replaces only the external credential lookup.
private struct ActionCredentials: CredentialStoring {
  /// Optional synthetic token.
  let token: String?
  func read() throws -> String? { token }
  func save(_ value: String) throws {}
  func remove() throws {}
}

/// Supplies controlled external responses while all authorization and processing remain real.
private actor ActionProvider: MovieMetadataProvider {
  /// Provider calls recorded to distinguish a saved selection from an automatic search.
  private(set) var searches: [String] = []
  /// Regional search language recorded at the actual metadata provider boundary.
  private(set) var searchLanguages: [String] = []
  /// Downloaded poster paths establish whether refresh used the saved movie.
  private(set) var downloads: [String] = []
  /// Optional real configuration change during the asynchronous network boundary.
  let repository: ConfigurationRepository?
  /// Whether configuration changes at the later artwork boundary instead of during search.
  let changesDuringDownload: Bool
  /// Whether metadata retrieval reports cancellation.
  let cancels: Bool

  /// Creates deterministic metadata with optional configuration invalidation or cancellation.
  init(repository: ConfigurationRepository? = .none, cancels: Bool = false, changesDuringDownload: Bool = false) {
    self.repository = repository
    self.cancels = cancels
    self.changesDuringDownload = changesDuringDownload
  }

  /// Supplies completed empty alternative-title evidence for this focused fixture.
  func alternativeTitles(movieID: Int) throws -> MovieAlternativeTitles { [movieID: []] }

  func searchMovies(title: String, year: Int?, language: TMDbLanguage = .english) throws -> MovieSearchResult {
    searches.append("\(title):\(year.map(String.init) ?? "none")")
    searchLanguages.append(language.rawValue)
    if cancels { throw CancellationError() }
    if !changesDuringDownload { try repository?.update { $0.credentialRevision = UUID() } }

    return MovieSearchResult(movies: [MovieMetadata(id: 7, title: "Dune", originalTitle: "Dune",
      releaseYear: 2021, posterPath: "/chosen.png")], hasMorePages: false)
  }

  func downloadPoster(path: String) throws -> Data {
    downloads.append(path)
    if changesDuringDownload { try repository?.update { $0.credentialRevision = UUID() } }
    let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/TestPoster.png")

    return try Data(contentsOf: resources)
  }
}

/// Holds a real service search at its provider boundary without depending on clock delays.
private actor SuspendedActionProvider: MovieMetadataProvider {
  /// Whether the service reached the search boundary.
  private var hasStarted = false
  /// Waiter notified when search begins.
  private var startedWaiter: CheckedContinuation<Void, Never>?
  /// Provider response retained until the test explicitly permits it.
  private var responseWaiter: CheckedContinuation<MovieSearchResult, Never>?

  /// Waits for search entry so cancellation and replacement occur during real suspended work.
  func waitForSearch() async {
    guard !hasStarted else { return }
    await withCheckedContinuation { startedWaiter = $0 }
  }

  /// Releases an empty completed search without manufacturing a matched movie.
  func finishSearch() {
    responseWaiter?.resume(returning: MovieSearchResult(movies: [], hasMorePages: false))
    responseWaiter = .none
  }

  /// Supplies completed empty alternative-title evidence for this focused fixture.
  func alternativeTitles(movieID: Int) throws -> MovieAlternativeTitles { [movieID: []] }

  func searchMovies(title: String, year: Int?, language: TMDbLanguage = .english) async -> MovieSearchResult {
    hasStarted = true
    startedWaiter?.resume()
    startedWaiter = .none

    return await withCheckedContinuation { responseWaiter = $0 }
  }

  func downloadPoster(path: String) throws -> Data { throw TMDbError.invalidPosterPath }
}

/// Covers stale provider results across search and artwork suspension points.
struct MoviePosterActionServiceConfigurationTests {
  /// A configuration revision changed during provider suspension invalidates its result.
  @Test func configurationChangeDuringSearchRejectsResults() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let movieMetadataProvider = ActionProvider(repository: fixture.repository)
    await #expect {
      try await fixture.service(movieMetadataProvider: movieMetadataProvider).searchMovies(
        for: fixture.request, query: "Dune", year: .none)
    } throws: { error in
      if case ConfigurationError.configurationChanged = error { return true }

      return false
    }
  }

  /// A configuration change during poster download must stop the final change guard.
  @Test func configurationChangeDuringArtworkPreventsChange() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let movieMetadataProvider = ActionProvider(repository: fixture.repository, changesDuringDownload: true)
    let activity = ActivityServiceFake()
    let movie = MovieMetadata(id: 7, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
      posterPath: "/chosen.png")
    do {
      _ = try await fixture.service(movieMetadataProvider: movieMetadataProvider, activity: activity)
        .applyPoster(movie, for: fixture.request)
      Issue.record("Artwork from an obsolete configuration must not mutate the folder")
    } catch ConfigurationError.configurationChanged {}
    #expect(try FileSystemService().readCurrentState(ofChild: fixture.request.childName, in: fixture.movies)
      .hasCustomIcon == false)
    #expect(try await activity.entries().map(\.event).filter { $0.folderResult == .none }.map(\.status)
      == [.started, .failed])
  }

}
