import FileSystem
import FinderSync
import Foundation
import MovieFolderCommon
@testable import MovieFolderFinder
import Network
import Persistence
import Synchronization
import Testing

/// Temporary filesystem, grants, and repositories owned by one integration test.
struct FinderFixture: Sendable {
  /// Isolated container removed after each test.
  let container: URL
  /// Real collection root used by authorization and selection validation.
  let root: URL
  /// Persisted root authorization and identity.
  let directory: MonitoredDirectory
  /// Current settings backed by real persistence leases.
  let repository: ConfigurationRepository

  /// Creates a real root and transfer bookmark without App Group or Keychain access.
  init() throws {
    container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    root = container.appendingPathComponent("Collection", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let service = FileSystemService()
    directory = MonitoredDirectory(id: UUID(), path: root.path,
      transferBookmark: try service.makeTransferBookmark(for: root), authorizationVersion: UUID(),
      identity: try service.persistentDirectoryIdentity(at: root))
    repository = try ConfigurationRepository(
      store: PersistenceStore(directory: container.appendingPathComponent("Settings")))
    try repository.update { $0.directories = [directory] }
  }

  /// Creates an immediate movie folder with real filesystem identity.
  func movie(_ name: String = "Arrival (2016)") throws -> URL {
    let child = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

    return child
  }

  /// Removes only the test-owned tree.
  func remove() { try? FileManager.default.removeItem(at: container) }
}

/// Stores registration evidence without touching Finder's contextMenuHandler.
@MainActor final class FinderRegistrations {
  /// Complete sequence of registered root snapshots.
  private(set) var roots: [Set<URL>] = []
  /// Captures a registration operation.
  func append(_ registered: Set<URL>) { roots.append(registered) }
}

/// Silences external notifications while retaining real activity persistence.
struct QuietActivityNotifier: MovieFolderActivityChangeNotifying {
  func movieFolderActivityDidChange() {}
}

/// Supplies deterministic provider results; no network request or icon write is needed for missing posters.
struct NoMatchesProvider: MovieMetadataProvider {
  func searchMovies(title: String, year: Int?) throws -> MovieSearchResult {
    try Task.checkCancellation()

    return MovieSearchResult(movies: [], hasMorePages: false)
  }
  func downloadPoster(path: String) throws -> Data { throw TMDbError.invalidPosterPath }
}

/// Counts actual provider admission for a cached Finder runtime across gate changes.
actor CountingNoMatchesProvider: MovieMetadataProvider {
  /// Number of searches that reached the underlying movieMetadataProvider.
  private(set) var searchCount = Int.zero

  func searchMovies(title: String, year: Int?) throws -> MovieSearchResult {
    searchCount += 1

    return MovieSearchResult(movies: [], hasMorePages: false)
  }

  func downloadPoster(path: String) throws -> Data { throw TMDbError.invalidPosterPath }
}

/// Suspends an external response so cancellation and settings changes occur at a known boundary.
actor SuspendedFinderProvider: MovieMetadataProvider {
  /// Response continuation resumed explicitly by the test after changing authorization or cancellation.
  private var response: CheckedContinuation<MovieSearchResult, Never>?
  /// Waiters notified once provider work has started.
  private var started: CheckedContinuation<Void, Never>?
  /// Tracks provider entry even when it precedes registration of the waiter.
  private var hasStarted = false

  func searchMovies(title: String, year: Int?) async throws -> MovieSearchResult {
    hasStarted = true
    started?.resume()
    started = .none

    return await withCheckedContinuation { response = $0 }
  }

  func downloadPoster(path: String) throws -> Data { throw TMDbError.invalidPosterPath }

  /// Waits deterministically until processing has crossed into provider work.
  func waitUntilStarted() async {
    if hasStarted { return }
    await withCheckedContinuation { started = $0 }
  }

  /// Delivers a late successful response, intentionally ignoring task cancellation like an external boundary may.
  func finish() {
    response?.resume(returning: MovieSearchResult(movies: [], hasMorePages: false))
    response = .none
  }
}

/// Retains synchronized provider composition evidence across copies of the injected environment.
final class FinderProviderCollections: Sendable {
  /// Root identifiers passed to provider construction.
  let collectionIDs = Mutex<[UUID]>([])
}

/// Shares only the test-controlled availability of a current settings read.
final class FinderConfigurationReadControl: Sendable {
  /// Test switch that makes only the current configuration read unavailable.
  let failsCurrentRead = Mutex(false)
}

/// Restores public history during the request to verify that unknown capture privacy remains private.
struct PublicHistoryRestoringProvider: MovieMetadataProvider {
  /// Repository whose privacy choice is changed while the simulated provider request is in flight.
  let repository: ConfigurationRepository
  /// Controls whether the production composition can read current collection settings.
  let configurationReadControl: FinderConfigurationReadControl

  func searchMovies(title: String, year: Int?) throws -> MovieSearchResult {
    try repository.update { $0.directories[0].usesPrivateHistory = false }
    configurationReadControl.failsCurrentRead.withLock { $0 = false }

    return MovieSearchResult(movies: [], hasMorePages: false)
  }

  func downloadPoster(path: String) throws -> Data { throw TMDbError.invalidImage }
}

/// Redirects system boundaries into one test-owned container while retaining runtime configuration.
struct IsolatedFinderEnvironment: FinderRuntimeEnvironment {
  /// Real test-owned repositories and collection.
  let fixture: FinderFixture
  /// Captured configuration registration sequence.
  let registrations: FinderRegistrations
  /// Activity history used to verify terminal behavior.
  let activity: any MovieFolderActivityServicing
  /// Simulates absent credentials without opening Keychain.
  var token: String? = "fixture-token"
  /// Allows explicit build-evidence absence and access failures.
  var buildVersion: (String, String)? = ("1.2.3", "45")
  /// Forces creation failure at the provider boundary.
  var providerFailure = false
  /// Injects an unavailable current-privacy read independently of retained processing authorization.
  let configurationReadControl = FinderConfigurationReadControl()
  /// Injects a controlled metadata source while the production processor remains real.
  var movieMetadataProvider: any MovieMetadataProvider = NoMatchesProvider()
  /// Captures collection-specific composition without exposing request or folder contents.
  let providerCollections = FinderProviderCollections()

  /// Creates isolated runtime dependencies and a recorder rooted in the fixture container.
  /// - Parameter fixture: Test-owned stores and authorized root.
  @MainActor init(_ fixture: FinderFixture) {
    self.fixture = fixture
    registrations = FinderRegistrations()
    activity = MovieFolderActivityRecorder(directory: fixture.container.appendingPathComponent("Activity"),
      notifier: QuietActivityNotifier(), configurationRepository: fixture.repository)
  }

  func configurationRepository() throws -> ConfigurationRepository {
    if configurationReadControl.failsCurrentRead.withLock({ $0 }) { throw ConfigurationError.busy }

    return fixture.repository
  }
  func authorizationStore() throws -> PersistenceStore {
    try PersistenceStore(directory: fixture.container.appendingPathComponent("Authorization"))
  }
  func containerURL() throws -> URL { fixture.container }
  func credential() throws -> String? { token }
  func movieMetadataProvider(token: String, configuration: DirectoryConfiguration) throws -> any MovieMetadataProvider {
    if providerFailure { throw TMDbError.authentication }

    return movieMetadataProvider
  }
  /// Records the root scope passed to each independently composed movie metadata provider.
  func movieMetadataProvider(
    token: String, configuration: DirectoryConfiguration, collectionID: UUID
  ) throws -> any MovieMetadataProvider {
    providerCollections.collectionIDs.withLock { $0.append(collectionID) }

    return try movieMetadataProvider(token: token, configuration: configuration)
  }
  func processingStore() throws -> CollectionProcessingStore {
    try CollectionProcessingStore(
      store: PersistenceStore(directory: fixture.container.appendingPathComponent("Outcomes")),
      configuration: fixture.repository)
  }
  func acquireDirectoryAccess(
    bookmark: Data, securityScoped: Bool, expectedIdentity: String?
  ) throws -> DirectoryAccess {
    // Tests cannot establish extension security scope; real bookmark/descriptor/identity validation remains.
    try FileSystemService().acquireDirectoryAccess(
      bookmark: bookmark, securityScoped: false, expectedIdentity: expectedIdentity)
  }
  func makeDirectoryBookmark(for url: URL) throws -> Data { try FileSystemService().makeTransferBookmark(for: url) }
  @MainActor func register(_ roots: Set<URL>) { registrations.append(roots) }
}

/// Test-owned menu boundary records requests rather than launching the host application.
final class IsolatedContextMenuEnvironment: MovieFolderContextMenuEnvironment {
  /// Captured read-only routes never invoke a clipboard or Finder effect.
  var contextMenuRequests: [MovieFolderContextMenuRequest] = []
  func open(_ request: MovieFolderContextMenuRequest) { contextMenuRequests.append(request) }
  /// Captured inclusion requests dispatched for host confirmation.
  var contextMenuInclusionRequests: [MovieFolderInclusionRequest] = []
  /// Retains typed inclusion requests without mutating configuration.
  func open(_ request: MovieFolderInclusionRequest) { contextMenuInclusionRequests.append(request) }
  /// Selection under test, including unsupported files and hidden folders.
  var selection: [URL]?
  /// Real isolated configuration repository.
  let repository: ConfigurationRepository
  /// Captured host requests, proving menu generation isolation.
  var opened: [MoviePosterRequest] = []
  /// Captures the isolated configuration and Finder selection used by menu tests.
  /// - Parameters:
  ///   - repository: Configuration against which selections are validated.
  ///   - selection: Selected URLs, or `.none` when Finder supplies no selection.
  init(repository: ConfigurationRepository, selection: [URL]?) {
    self.repository = repository
    self.selection = selection
  }
  func selectedItemURLs() -> [URL]? { selection }
  func configurationRepository() throws -> ConfigurationRepository { repository }
  func open(_ request: MoviePosterRequest) { opened.append(request) }
}

/// Stands in for Finder's principal object while forwarding its menu selector to the request owner.
final class ContextMenuActionTarget: NSObject {
  @objc func openContextMenuRequest(_ sender: NSMenuItem) { contextMenuHandler.openContextMenuRequest(sender) }
  /// Routes inclusion selectors using the same retained contextual-menu handler.
  @objc func openContextMenuInclusionAction(_ sender: NSMenuItem) {
    contextMenuHandler.openContextMenuInclusionAction(sender)
  }
  /// Handler that retains validated requests for the current menu generation.
  private let contextMenuHandler: MovieFolderContextMenuHandler

  /// Retains the handler used by the isolated Finder menu test.
  /// - Parameter contextMenuHandler: Owner of the captured menu requests.
  init(contextMenuHandler: MovieFolderContextMenuHandler) {
    self.contextMenuHandler = contextMenuHandler
    super.init()
  }

  /// Routes the same selector implemented by the production Finder principal object.
  @objc func openContextMenuPosterAction(_ sender: NSMenuItem) {
    contextMenuHandler.openContextMenuPosterAction(sender)
  }
}
