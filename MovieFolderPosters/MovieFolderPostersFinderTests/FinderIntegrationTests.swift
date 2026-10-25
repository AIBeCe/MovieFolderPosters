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
private struct FinderFixture: Sendable {
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

/// Stores registration evidence without touching Finder's controller.
@MainActor private final class FinderRegistrations {
  /// Complete sequence of registered root snapshots.
  private(set) var roots: [Set<URL>] = []
  /// Captures a registration operation.
  func append(_ registered: Set<URL>) { roots.append(registered) }
}

/// Silences external notifications while retaining real activity persistence.
private struct QuietActivityNotifier: MovieFolderActivityChangeNotifying {
  func movieFolderActivityDidChange() {}
}

/// Supplies deterministic provider results; no network request or icon write is needed for missing posters.
private struct NoMatchesProvider: MovieMetadataProvider {
  func searchMovies(title: String, year: Int?) throws -> MovieSearchResult {
    try Task.checkCancellation()

    return MovieSearchResult(movies: [], hasMorePages: false)
  }
  func downloadPoster(path: String) throws -> Data { throw TMDbError.invalidPosterPath }
}

/// Counts actual provider admission for a cached Finder runtime across gate changes.
private actor CountingNoMatchesProvider: MovieMetadataProvider {
  /// Number of searches that reached the underlying movieMetadataProvider.
  private(set) var searchCount = Int.zero

  func searchMovies(title: String, year: Int?) throws -> MovieSearchResult {
    searchCount += 1

    return MovieSearchResult(movies: [], hasMorePages: false)
  }

  func downloadPoster(path: String) throws -> Data { throw TMDbError.invalidPosterPath }
}

/// Suspends an external response so cancellation and settings changes occur at a known boundary.
private actor SuspendedFinderProvider: MovieMetadataProvider {
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
private final class FinderProviderCollections: Sendable {
  /// Root identifiers passed to provider construction.
  let collectionIDs = Mutex<[UUID]>([])
}

/// Shares only the test-controlled availability of a current settings read.
private final class FinderConfigurationReadControl: Sendable {
  let failsCurrentRead = Mutex(false)
}

/// Restores public history during the request to verify that unknown capture privacy remains private.
private struct PublicHistoryRestoringProvider: MovieMetadataProvider {
  let repository: ConfigurationRepository
  let configurationReadControl: FinderConfigurationReadControl

  func searchMovies(title: String, year: Int?) throws -> MovieSearchResult {
    try repository.update { $0.directories[0].usesPrivateHistory = false }
    configurationReadControl.failsCurrentRead.withLock { $0 = false }

    return MovieSearchResult(movies: [], hasMorePages: false)
  }

  func downloadPoster(path: String) throws -> Data { throw TMDbError.invalidImage }
}

/// Redirects system boundaries into one test-owned container while retaining runtime configuration.
private struct IsolatedFinderEnvironment: FinderRuntimeEnvironment {
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
private final class IsolatedMenuPlatform: FinderMenuPlatform {
  /// Captured inclusion requests dispatched for host confirmation.
  var inclusionRequests: [MovieFolderInclusionRequest] = []
  /// Retains typed inclusion requests without mutating configuration.
  func open(_ request: MovieFolderInclusionRequest) { inclusionRequests.append(request) }
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
private final class FinderMenuActionTarget: NSObject {
  /// Routes inclusion selectors using the same retained menu controller.
  @objc func openInclusionAction(_ sender: NSMenuItem) { controller.openInclusionAction(sender) }
  /// Controller that retains validated requests for the current menu generation.
  private let controller: FinderMenuController

  /// Retains the controller used by the isolated Finder menu test.
  /// - Parameter controller: Owner of the captured menu requests.
  init(controller: FinderMenuController) {
    self.controller = controller
    super.init()
  }

  /// Routes the same selector implemented by the production Finder principal object.
  @objc func openPosterAction(_ sender: NSMenuItem) { controller.openPosterAction(sender) }
}

/// Exercises Finder menu capture, runtime authorization, and persisted processing boundaries.
@Suite("Finder integration")
struct FinderIntegrationTests {
  /// A failed current privacy read cannot reuse an earlier public choice when privacy changes during work.
  @Test @MainActor func unavailablePrivacyCaptureRemainsPrivateAfterPublicHistoryRestored() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    _ = try fixture.movie()
    var environment = IsolatedFinderEnvironment(fixture)
    environment.movieMetadataProvider = PublicHistoryRestoringProvider(repository: fixture.repository,
      configurationReadControl: environment.configurationReadControl)
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = DirectoryObservationScheduler(delegate: runtime)
    _ = await runtime.directoryObservationSchedulerLoadRoots(scheduler)
    try fixture.repository.update { $0.directories[0].usesPrivateHistory = true }
    environment.configurationReadControl.failsCurrentRead.withLock { $0 = true }
    _ = try await runtime.directoryObservationScheduler(scheduler, process: fixture.root)
    let events = try await environment.activity.entries().map(\.event)
      .filter { $0.action == .automaticProcessing }

    #expect(!events.isEmpty)
    #expect(events.allSatisfy { $0.target == .none && $0.collectionID == .none && $0.activityGroupID == .none })
    #expect(try fixture.repository.read().directories.first?.usesPrivateHistory == false)
  }

  /// Completed runs name the observed collection and report this visit's actual counters.
  @Test @MainActor func automaticActivityIdentifiesCollectionAndRunCounts() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    _ = try fixture.movie()
    let environment = IsolatedFinderEnvironment(fixture)
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = DirectoryObservationScheduler(delegate: runtime)
    _ = await runtime.directoryObservationSchedulerLoadRoots(scheduler)
    _ = try await runtime.directoryObservationScheduler(scheduler, process: fixture.root)
    let recordedMessages = try await environment.activity.entries().map { $0.event.text }

    #expect(recordedMessages.contains { $0.contains("Collection") && $0.contains("unresolved") && $0.contains("1") })
    #expect(recordedMessages.contains { $0.contains("Arrival (2016)") })
  }

  /// Pausing keeps Finder registration and a credential-free Include action available.
  @Test @MainActor func pausedExcludedFolderOffersIncludeWithoutMutatingConfiguration() throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    let child = try fixture.movie()
    let identity = try FileSystemService().readCurrentState(ofChild: child.lastPathComponent, in: fixture.root).identity
    try fixture.repository.update {
      $0.directories[0].processingConfiguration.setPaused(true)
      $0.directories[0].processingConfiguration.excludeFolder(identity: identity, lastKnownName: child.lastPathComponent)
    }
    let before = try fixture.repository.read()
    let platform = IsolatedMenuPlatform(repository: fixture.repository, selection: [child])
    let controller = FinderMenuController(platform: platform)
    let target = FinderMenuActionTarget(controller: controller)
    let menu = try #require(controller.menu(for: .contextualMenuForItems, actionTarget: target))
    let include = try #require(menu.items.first(where: { $0.title == "Include Folder…" }))
    controller.openInclusionAction(include)
    #expect(platform.inclusionRequests.first?.action == .include)
    #expect(platform.inclusionRequests.first?.expectedProcessingConfigurationRevision
      == before.directories[0].processingConfiguration.revision)
    #expect(try fixture.repository.read() == before)
  }

  /// Verifies menu requests capture folder identity and reject tags from an older menu.
  @Test @MainActor func menuCapturesIdentityAndExpiresOlderTags() throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    let child = try fixture.movie()
    let platform = IsolatedMenuPlatform(repository: fixture.repository, selection: [child])
    let controller = FinderMenuController(platform: platform)
    let actionTarget = FinderMenuActionTarget(controller: controller)
    let first = try #require(controller.menu(for: .contextualMenuForItems, actionTarget: actionTarget))
    #expect(first.items.count == MoviePosterAction.allCases.count + 1)
    #expect(first.items.allSatisfy { $0.target === actionTarget })
    #expect(controller.menu(for: .contextualMenuForContainer, actionTarget: actionTarget) == .none)
    for item in first.items {
      let target = try #require(item.target as? NSObject)
      let action = try #require(item.action)
      #expect(target.responds(to: action))
      _ = target.perform(action, with: item)
    }
    #expect(platform.opened.map(\.action) == MoviePosterAction.allCases)
    #expect(platform.inclusionRequests.first?.action == .exclude)
    #expect(platform.inclusionRequests.first?.folderURL.path == child.path)
    #expect(platform.opened.allSatisfy { $0.rootID == fixture.directory.id && $0.childName == child.lastPathComponent })
    let identity = try FileSystemService().readCurrentState(ofChild: child.lastPathComponent, in: fixture.root).identity
    #expect(platform.opened.allSatisfy { $0.identity == identity })
    let secondChild = try fixture.movie("Dune (2021)")
    platform.selection = [secondChild]
    let second = try #require(controller.menu(for: .contextualMenuForItems, actionTarget: actionTarget))
    controller.openPosterAction(try #require(first.items.first(where: { $0.title.hasPrefix("Movie Poster:") })))
    #expect(platform.opened.count == MoviePosterAction.allCases.count)
    controller.openPosterAction(try #require(second.items.first(where: { $0.title.hasPrefix("Movie Poster:") })))
    #expect(platform.opened.last?.childName == "Dune (2021)")
    platform.selection = []
    #expect(controller.menu(for: .contextualMenuForItems, actionTarget: actionTarget) == .none)
    controller.openPosterAction(try #require(second.items.first(where: { $0.title.hasPrefix("Movie Poster:") })))
    #expect(platform.opened.count == MoviePosterAction.allCases.count + 1)
  }

  /// Rejects mixed, hidden, nested, and unsupported Finder selections.
  @Test @MainActor func selectionRejectsUnsupportedBoundaries() throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    let movie = try fixture.movie()
    let hidden = try fixture.movie(".hidden")
    let nested = movie.appendingPathComponent("Nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let file = fixture.root.appendingPathComponent("Movie.mkv")
    try Data().write(to: file)
    let platform = IsolatedMenuPlatform(repository: fixture.repository, selection: .none)
    let controller = FinderMenuController(platform: platform)
    for selection in [.none, [], [movie, hidden], [hidden], [fixture.root], [nested], [file]] as [[URL]?] {
      platform.selection = selection
      #expect(controller.menu(for: .contextualMenuForItems, actionTarget: controller) == .none)
    }
    platform.selection = [movie]
    #expect(controller.menu(for: .contextualMenuForContainer, actionTarget: controller) == .none)
    #expect(FinderMenuController(platform: platform, firstMenuTag: Int.max)
      .menu(for: .contextualMenuForItems, actionTarget: controller) == .none)
    try fixture.repository.update { $0.directories = [] }
    #expect(controller.menu(for: .contextualMenuForItems, actionTarget: controller) == .none)
  }

}

// MARK: - Configuration and processing
extension FinderIntegrationTests {
  /// Each root receives its own request-history context instead of sharing another root's provider context.
  @Test @MainActor func providersAreComposedWithTheirCollectionIdentity() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    let secondRoot = fixture.container.appendingPathComponent("Second Collection", isDirectory: true)
    try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
    let fileSystem = FileSystemService()
    let secondDirectory = MonitoredDirectory(
      id: UUID(), path: secondRoot.path, transferBookmark: try fileSystem.makeTransferBookmark(for: secondRoot),
      authorizationVersion: UUID(), identity: try fileSystem.persistentDirectoryIdentity(at: secondRoot))
    try fixture.repository.update { $0.directories.append(secondDirectory) }
    let environment = IsolatedFinderEnvironment(fixture)
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = DirectoryObservationScheduler(delegate: runtime)

    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler) == [fixture.root, secondRoot])
    #expect(Set(environment.providerCollections.collectionIDs.withLock { $0 })
      == [fixture.directory.id, secondDirectory.id])
  }

  /// Paused roots stay registered while visits create no processing operation or provider request.
  @Test @MainActor func pausedRootRemainsRegisteredWithoutProcessingActivity() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    _ = try fixture.movie()
    try fixture.repository.update { $0.directories[0].processingConfiguration.setPaused(true) }
    var environment = IsolatedFinderEnvironment(fixture)
    let movieMetadataProvider = CountingNoMatchesProvider()
    environment.movieMetadataProvider = movieMetadataProvider
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = DirectoryObservationScheduler(delegate: runtime)
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler) == [fixture.root])
    #expect(try await runtime.directoryObservationScheduler(scheduler, process: fixture.root) == .none)
    #expect(await movieMetadataProvider.searchCount == .zero)
    #expect(try environment.processingStore().read(rootID: fixture.directory.id) == .none)
    #expect(try await environment.activity.entries().map(\.event).filter { $0.folderResult == .none }.map(\.status)
      == [.succeeded])
    #expect(environment.registrations.roots == [[fixture.root]])
  }

  /// A cached live runtime must recheck durable mode after composition and resume only on a later visit.
  @Test @MainActor func cachedRuntimeHonorsDurableRecoveryMode() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    _ = try fixture.movie()
    var environment = IsolatedFinderEnvironment(fixture)
    let movieMetadataProvider = CountingNoMatchesProvider()
    environment.movieMetadataProvider = movieMetadataProvider
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = DirectoryObservationScheduler(delegate: runtime)
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler) == [fixture.root])
    let recovery = try environment.processingRecoveryService()
    try recovery.setRecoveryModeEnabled(true)
    await #expect(throws: ProcessingRecoveryError.recoveryMode) {
      try await runtime.directoryObservationScheduler(scheduler, process: fixture.root)
    }
    #expect(await movieMetadataProvider.searchCount == .zero)
    let paused = try environment.processingStore().read(rootID: fixture.directory.id)
    #expect(paused?.folders.contains { $0.state == .notFound } != true)
    try recovery.setRecoveryModeEnabled(false)
    #expect(try environment.processingStore().read(rootID: fixture.directory.id) == paused)
    try await runtime.directoryObservationScheduler(scheduler, process: fixture.root)
    let resumed = try #require(try environment.processingStore().read(rootID: fixture.directory.id))
    #expect(resumed.folders.first?.state == .notFound)
    #expect(await movieMetadataProvider.searchCount == 1)
  }

  /// Verifies authorized processing saves activation evidence and a complete not-found outcome.
  @Test @MainActor func authorizedRootWritesActivationAndAuthoritativeNotFoundOutcome() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    _ = try fixture.movie()
    let environment = IsolatedFinderEnvironment(fixture)
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = DirectoryObservationScheduler(delegate: runtime)
    let roots = await runtime.directoryObservationSchedulerLoadRoots(scheduler)
    #expect(roots == [fixture.root])
    try await runtime.directoryObservationScheduler(scheduler, process: fixture.root)
    let state = try #require(try environment.processingStore().read(rootID: fixture.directory.id))
    #expect(state.context.authorizationVersion == fixture.directory.authorizationVersion)
    #expect(state.context.rootIdentity == fixture.directory.identity)
    #expect(state.folders.count == 1)
    #expect(state.folders.first?.state == .notFound)
    let store = try PersistenceStore(directory: fixture.container.appendingPathComponent("Readiness"))
    let persistenceAccess = try #require(try store.acquireAccess(for: ExtensionReadinessReceipt.recordKey))
    let receipt = try JSONDecoder().decode(ExtensionReadinessReceipt.self, from: #require(try persistenceAccess.read()))
    #expect(receipt.version == "1.2.3" && receipt.build == "45")
    let activity = try await environment.activity.entries()
    #expect(activity.map(\.event).filter { $0.folderResult == .none }.map(\.status)
      == [.succeeded, .started, .succeeded])
    #expect(activity.contains { $0.event.folderResult == .notFound })
    #expect(activity.last?.event.processingSummary?.unresolved == 1)
    #expect(activity.allSatisfy { $0.event.activityGroupID == .none || $0.event.collectionID == fixture.directory.id })
  }
  /// Keeps authorized roots registered while coalescing missing-credential diagnostics.
  @Test @MainActor func missingCredentialRetainsRootsAndSuppressesRepeatedUnavailableEvents() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    var environment = IsolatedFinderEnvironment(fixture)
    environment.token = .none
    environment.buildVersion = .none
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = DirectoryObservationScheduler(delegate: runtime)
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler) == [fixture.root])
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler) == [fixture.root])
    try await runtime.directoryObservationScheduler(scheduler, process: fixture.root)
    #expect(try environment.processingStore().read(rootID: fixture.directory.id) == .none)
    #expect(try await environment.activity.entries().map(\.event).filter { $0.folderResult == .none }.map(\.status)
      == [.unavailable])
    #expect(environment.registrations.roots == [[fixture.root], [fixture.root]])
  }

  /// Keeps root authorization after metadata-provider creation fails.
  @Test @MainActor func providerCreationFailureDoesNotRevokeAuthorizedRoot() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    var environment = IsolatedFinderEnvironment(fixture)
    environment.providerFailure = true
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = DirectoryObservationScheduler(delegate: runtime)
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler) == [fixture.root])
    #expect(try await environment.activity.entries().map(\.event).filter { $0.folderResult == .none }.map(\.status)
      == [.unavailable])
    try await runtime.directoryObservationScheduler(scheduler, process: fixture.root)
    #expect(try environment.processingStore().read(rootID: fixture.directory.id) == .none)
  }

  /// Rejects captured work after saved processing settings change.
  @Test @MainActor func changedSettingsInvalidateCapturedChangeAndProcessingContext() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    let environment = IsolatedFinderEnvironment(fixture)
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = DirectoryObservationScheduler(delegate: runtime)
    _ = await runtime.directoryObservationSchedulerLoadRoots(scheduler)
    try fixture.repository.update { $0.credentialRevision = UUID() }
    await #expect(throws: (any Error).self) {
      try await runtime.directoryObservationScheduler(scheduler, process: fixture.root)
    }
    #expect(try await environment.activity.entries().map(\.event).filter { $0.folderResult == .none }.map(\.status)
      == [.succeeded, .started, .failed])
    #expect(try environment.processingStore().read(rootID: fixture.directory.id) == .none)
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler) == [fixture.root])
    try await runtime.directoryObservationScheduler(scheduler, process: fixture.root)
    let current = try fixture.repository.read()
    let saved = try #require(try environment.processingStore().read(rootID: fixture.directory.id))
    #expect(saved.context.credentialRevision == current.credentialRevision)
  }

  /// Clears Finder registration and invalidates the prior processor after configuration corruption.
  @Test @MainActor func corruptSettingsClearRegistrationAndDisablePriorProcessor() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    let environment = IsolatedFinderEnvironment(fixture)
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = DirectoryObservationScheduler(delegate: runtime)
    _ = await runtime.directoryObservationSchedulerLoadRoots(scheduler)
    let store = try PersistenceStore(directory: fixture.container.appendingPathComponent("Settings"))
    do {
      let persistenceAccess = try #require(try store.acquireAccess(for: ConfigurationRepository.recordKey))
      try persistenceAccess.write(Data("malformed".utf8))
    }
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler).isEmpty)
    try await runtime.directoryObservationScheduler(scheduler, process: fixture.root)
    #expect(environment.registrations.roots == [[fixture.root], []])
    #expect(try await environment.activity.entries().map(\.event).filter { $0.folderResult == .none }.map(\.status)
      == [.succeeded, .unavailable])
  }

  /// Rejects roots whose authorization or overlap violates registration boundaries.
  @Test @MainActor func invalidAuthorizationAndOverlappingRootsAreNeverRegistered() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    let environment = IsolatedFinderEnvironment(fixture)
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = DirectoryObservationScheduler(delegate: runtime)
    try fixture.repository.update { $0.directories[0].transferBookmark = Data("invalid".utf8) }
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler).isEmpty)
    let nested = try fixture.movie()
    let service = FileSystemService()
    let directory = MonitoredDirectory(id: UUID(), path: nested.path,
      transferBookmark: try service.makeTransferBookmark(for: nested), authorizationVersion: UUID(),
      identity: try service.persistentDirectoryIdentity(at: nested))
    try fixture.repository.update { $0.directories = [fixture.directory, directory] }
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler).isEmpty)
  }

  /// Rejects a replaced folder before starting metadata requests.
  @Test @MainActor func identityReplacementFailsBeforeProviderWork() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    let environment = IsolatedFinderEnvironment(fixture)
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = DirectoryObservationScheduler(delegate: runtime)
    _ = await runtime.directoryObservationSchedulerLoadRoots(scheduler)
    try FileManager.default.moveItem(at: fixture.root, to: fixture.container.appendingPathComponent("OldCollection"))
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
    await #expect(throws: DirectoryAccessError.identityChanged) {
      try await runtime.directoryObservationScheduler(scheduler, process: fixture.root)
    }
    #expect(try await environment.activity.entries().map(\.event).filter { $0.folderResult == .none }.map(\.status)
      == [.succeeded, .started, .failed])
  }

  /// Records cancellation without converting it into a processing failure.
  @Test @MainActor func cancelledVisitRecordsCancelledAndPreservesCancellation() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    let environment = IsolatedFinderEnvironment(fixture)
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = DirectoryObservationScheduler(delegate: runtime)
    _ = await runtime.directoryObservationSchedulerLoadRoots(scheduler)
    let visit = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await runtime.directoryObservationScheduler(scheduler, process: fixture.root)
    }
    await #expect(throws: CancellationError.self) { try await visit.value }
    #expect(try await environment.activity.entries().map(\.event).filter { $0.folderResult == .none }.map(\.status)
      == [.succeeded, .started, .cancelled])
  }

}

// MARK: - Authorization and system boundaries
extension FinderIntegrationTests {
  /// Keeps the configuration access alive and rejects root-identity changes before change.
  @Test @MainActor func configurationVerifierRetainsAccessAndRejectsChangedRoot() throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    let environment = IsolatedFinderEnvironment(fixture)
    let configuration = try fixture.repository.read()
    let access = try environment.acquireDirectoryAccess(bookmark: fixture.directory.transferBookmark,
      securityScoped: false, expectedIdentity: fixture.directory.identity)
    let identity = try #require(fixture.directory.identity)
    let verifier = FinderCollectionConfigurationVerifier(repository: fixture.repository, configuration: configuration,
      roots: [fixture.root: FinderConfigurationRuntime.AuthorizedRoot(directory: fixture.directory,
        access: access, identity: identity)])
    let processor = try MovieFolderProcessor(persistence: PersistenceStore(
      directory: fixture.container.appendingPathComponent("VerifierRecords")), provider: NoMatchesProvider(),
      cacheDirectory: fixture.container.appendingPathComponent("VerifierCache"))
    do {
      let held = try #require(try verifier.checkAutomaticProcessing(in: fixture.root))
      #expect(throws: ConfigurationError.self) { try fixture.repository.update { $0.credentialRevision = UUID() } }
      withExtendedLifetime(held) {}
    }
    #expect(throws: DirectoryAccessError.identityChanged) {
      try verifier.checkAutomaticProcessing(in: fixture.container)
    }
    try FileManager.default.moveItem(at: fixture.root, to: fixture.container.appendingPathComponent("Old"))
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
    #expect(throws: DirectoryAccessError.identityChanged) {
      try verifier.checkAutomaticProcessing(in: fixture.root)
    }
    // Failed identity validation releases the configuration access rather than blocking future edits.
    try fixture.repository.update { $0.credentialRevision = UUID() }
    #expect(throws: ConfigurationError.self) {
      try verifier.checkAutomaticProcessing(in: fixture.root)
    }
  }

  /// Keeps configuration responsive while activation storage is leased by another operation.
  @Test @MainActor func activationAccessContentionDoesNotBlockConfiguration() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    let environment = IsolatedFinderEnvironment(fixture)
    let store = try PersistenceStore(directory: fixture.container.appendingPathComponent("Readiness"))
    let held = try #require(try store.acquireAccess(for: ExtensionReadinessReceipt.recordKey))
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = DirectoryObservationScheduler(delegate: runtime)
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler) == [fixture.root])
    #expect(try held.read() == .none)
    withExtendedLifetime(held) {}
  }

  /// Rejects contended authorization records and bookmark paths that differ from the saved root.
  @Test @MainActor func authorizationAccessContentionAndMismatchedPathAreRejected() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    let environment = IsolatedFinderEnvironment(fixture)
    let store = try environment.authorizationStore()
    let key = "extension-\(fixture.directory.id)-\(fixture.directory.authorizationVersion)"
    do {
      let held = try #require(try store.acquireAccess(for: key))
      let runtime = FinderConfigurationRuntime(environment: environment)
      let scheduler = DirectoryObservationScheduler(delegate: runtime)
      #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler).isEmpty)
      withExtendedLifetime(held) {}
    }
    try fixture.repository.update { $0.directories[0].path = fixture.container.path }
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = DirectoryObservationScheduler(delegate: runtime)
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler).isEmpty)
  }

  /// Prevents a late metadata response from completing a cancelled visit.
  @Test @MainActor func lateProviderResponseCannotCompleteCancelledVisit() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    let movie = try fixture.movie()
    let movieMetadataProvider = SuspendedFinderProvider()
    var environment = IsolatedFinderEnvironment(fixture)
    environment.movieMetadataProvider = movieMetadataProvider
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = DirectoryObservationScheduler(delegate: runtime)
    _ = await runtime.directoryObservationSchedulerLoadRoots(scheduler)
    let operation = Task { try await runtime.directoryObservationScheduler(scheduler, process: fixture.root) }
    await movieMetadataProvider.waitUntilStarted()
    operation.cancel()
    await movieMetadataProvider.finish()
    await #expect(throws: CancellationError.self) { try await operation.value }
    let state = try #require(try environment.processingStore().read(rootID: fixture.directory.id))
    #expect(state.currentRun?.state == .interrupted)
    #expect(try !FileSystemService().readCurrentState(ofChild: movie.lastPathComponent, in: fixture.root).hasCustomIcon)
    #expect(try await environment.activity.entries().last?.event.status == .cancelled)
  }

  /// Prevents an older metadata request from committing after credential replacement.
  @Test @MainActor func lateProviderResponseCannotCommitUnderNewCredentialGeneration() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    _ = try fixture.movie()
    let movieMetadataProvider = SuspendedFinderProvider()
    var environment = IsolatedFinderEnvironment(fixture)
    environment.movieMetadataProvider = movieMetadataProvider
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = DirectoryObservationScheduler(delegate: runtime)
    _ = await runtime.directoryObservationSchedulerLoadRoots(scheduler)
    let operation = Task { try await runtime.directoryObservationScheduler(scheduler, process: fixture.root) }
    await movieMetadataProvider.waitUntilStarted()
    try fixture.repository.update { $0.credentialRevision = UUID() }
    await movieMetadataProvider.finish()
    await #expect(throws: (any Error).self) { try await operation.value }
    let state = try #require(try environment.processingStore().read(rootID: fixture.directory.id))
    #expect(state.currentRun?.state != .completed)
    #expect(state.context.credentialRevision != (try fixture.repository.read()).credentialRevision)
    #expect(try await environment.activity.entries().last?.event.status == .failed)
  }

  /// Checks live provider credential validation without contacting the metadata service.
  @Test func systemProviderCompositionValidatesCredentialsWithoutSendingNetworkRequests() throws {
    let system = SystemFinderRuntimeEnvironment()
    let settings = DirectoryConfiguration()
    #expect(throws: TMDbError.missingToken) { try system.movieMetadataProvider(token: "", configuration: settings) }
    #expect(try system.movieMetadataProvider(
      token: "isolated-composition-token", configuration: settings) is TMDbClient)
    var debugSettings = settings
    debugSettings.usesStubTMDbResponses = true
    // This standalone test bundle intentionally has no signed extension TestPoster resource.
    #expect(throws: FolderPosterError.invalidImage) {
      try system.movieMetadataProvider(token: "isolated-composition-token", configuration: debugSettings)
    }
  }

  /// Allows authorized processing to finish when activation evidence cannot be saved.
  @Test @MainActor func activationStorageFailureDoesNotBlockAuthorizedProcessing() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    try Data("not-a-directory".utf8).write(to: fixture.container.appendingPathComponent("Readiness"))
    let environment = IsolatedFinderEnvironment(fixture)
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = DirectoryObservationScheduler(delegate: runtime)
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler) == [fixture.root])
    try await runtime.directoryObservationScheduler(scheduler, process: fixture.root)
    #expect(try environment.processingStore().read(rootID: fixture.directory.id)?.currentRun?.state == .completed)
    #expect(try await environment.activity.entries().map(\.event).filter { $0.folderResult == .none }.map(\.status)
      == [.succeeded, .started, .succeeded])
  }

  /// Verifies the live authorization adapter retains a temporary root identity.
  @Test func systemAuthorizationAdapterPreservesTemporaryRootIdentity() throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    let system = SystemFinderRuntimeEnvironment()
    let bookmark = fixture.directory.transferBookmark
    let access = try system.acquireDirectoryAccess(bookmark: bookmark, securityScoped: false,
      expectedIdentity: fixture.directory.identity)
    #expect(access.url.standardizedFileURL == fixture.root)
    #expect(try FileSystemService().persistentDirectoryIdentity(at: access.url) == fixture.directory.identity)
    #expect(throws: DirectoryAccessError.identityChanged) {
      try system.acquireDirectoryAccess(bookmark: bookmark, securityScoped: false, expectedIdentity: "replaced")
    }
  }

}
