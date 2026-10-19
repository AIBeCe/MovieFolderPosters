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

  /// A concurrent authorization lease denies entry rather than running without coordination.
  @Test func authorizationContentionPreventsRead() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let directory = try #require(try fixture.repository.read().directories.first)
    let lease = try #require(try fixture.authorizations.acquireLease(
      for: "host-\(directory.id)-\(directory.authorizationVersion)"))
    await #expect { try await fixture.service().matchedMovieID(for: fixture.request) } throws: { error in
      if case ConfigurationError.busy = error { return true }

      return false
    }
    withExtendedLifetime(lease) {}
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
    let provider = ActionProvider()
    await #expect(throws: TMDbError.self) {
      try await fixture.service(token: "invalid\ntoken", provider: provider).searchMovies(
        for: fixture.request, query: "Dune", year: .none)
    }
    #expect(await provider.searches.isEmpty)
  }

  /// Selected IDs and artwork are validated before any authorization or mutation occurs.
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
    #expect(events.first?.operationID == events.last?.operationID)
    #expect(try FileSystemService().readCurrentState(ofChild: fixture.request.childName, in: fixture.movies)
      .hasCustomIcon == false)
  }

  /// Selection persists the chosen identity, refresh retains it, and removal clears the owned icon.
  @Test func selectionRefreshAndRemovalUseRealProcessing() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let provider = ActionProvider()
    let activity = ActivityServiceFake()
    let service = fixture.service(provider: provider, activity: activity)
    let movie = MovieMetadata(id: 7, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
      posterPath: "/chosen.png")
    #expect(try await service.applyPoster(movie, for: fixture.request) == 7)
    #expect(try await service.matchedMovieID(for: fixture.request) == 7)
    #expect(try await service.refreshPoster(for: fixture.request) == 7)
    #expect(try await service.removePoster(for: fixture.request))
    #expect(try await service.removePoster(for: fixture.request) == false)
    #expect(try await service.matchedMovieID(for: fixture.request) == .none)
    #expect(await provider.downloads == ["/chosen.png", "/chosen.png"])
    #expect(await provider.searches.isEmpty)
    #expect(try await activity.entries().map(\.event.status) == [
      .started, .succeeded, .started, .succeeded, .started, .succeeded, .started, .succeeded
    ])
  }

  /// Search trims user input and preserves the provider's pagination result.
  @Test func authorizedSearchPreservesQueryAndResults() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let provider = ActionProvider()
    let result = try await fixture.service(provider: provider).searchMovies(
      for: fixture.request, query: "  Dune  ", year: 2021)
    #expect(result.movies.map(\.id) == [7])
    #expect(!result.hasMorePages)
    #expect(await provider.searches == ["Dune:2021"])
  }

  /// A configuration revision changed during provider suspension invalidates its result.
  @Test func configurationChangeDuringSearchRejectsResults() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let provider = ActionProvider(repository: fixture.repository)
    await #expect {
      try await fixture.service(provider: provider).searchMovies(for: fixture.request, query: "Dune", year: .none)
    } throws: { error in
      if case ConfigurationError.configurationChanged = error { return true }

      return false
    }
  }

  /// A configuration change during poster download must stop the final mutation guard.
  @Test func configurationChangeDuringArtworkPreventsMutation() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let provider = ActionProvider(repository: fixture.repository, changesDuringDownload: true)
    let activity = ActivityServiceFake()
    let movie = MovieMetadata(id: 7, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
      posterPath: "/chosen.png")
    do {
      _ = try await fixture.service(provider: provider, activity: activity).applyPoster(movie, for: fixture.request)
      Issue.record("Artwork from an obsolete configuration must not mutate the folder")
    } catch ConfigurationError.configurationChanged {}
    #expect(try FileSystemService().readCurrentState(ofChild: fixture.request.childName, in: fixture.movies)
      .hasCustomIcon == false)
    #expect(try await activity.entries().map(\.event.status) == [.started, .failed])
  }

  /// Provider cancellation keeps a distinct cancelled event and leaves the folder untouched.
  @Test func cancelledRefreshRecordsCancellation() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let activity = ActivityServiceFake()
    let provider = ActionProvider(cancels: true)
    await #expect(throws: CancellationError.self) {
      try await fixture.service(provider: provider, activity: activity).refreshPoster(for: fixture.request)
    }
    #expect(try await activity.entries().map(\.event.status) == [.started, .cancelled])
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
  func service(token: String? = "fixture-token", provider: (any MovieMetadataProvider)? = .none,
               activity: (any MovieFolderActivityServicing)? = .none) -> MoviePosterActionService {
    MoviePosterActionService(credentials: ActionCredentials(token: token), activity: activity ?? ActivityServiceFake(),
      environment: self, provider: provider ?? ActionProvider())
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
  /// Downloaded poster paths establish whether refresh used the saved movie.
  private(set) var downloads: [String] = []
  /// Optional real configuration mutation during the asynchronous network boundary.
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

  func searchMovies(title: String, year: Int?) throws -> MovieSearchResult {
    searches.append("\(title):\(year.map(String.init) ?? "none")")
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
