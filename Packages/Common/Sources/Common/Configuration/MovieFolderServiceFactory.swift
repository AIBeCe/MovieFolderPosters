import Foundation
import OSLog
import Persistence

/// Builds app services using the storage locations of the calling process.
nonisolated public struct MovieFolderServiceFactory: Sendable {
  private let locations: any MovieFolderApplicationStorageLocations

  public init(locations: any MovieFolderApplicationStorageLocations) {
    self.locations = locations
  }

  /// Resolves the shared container for the calling process.
  public func appGroupContainerURL() throws -> URL { try locations.appGroupContainerURL() }

  /// Opens the shared locks used to coordinate collection processing.
  public func makeProcessingLockStore() throws -> PersistenceStore {
    let container = try locations.appGroupContainerURL()

    return try locations.makePersistenceStore(directory: container.appendingPathComponent("ProcessingLocks"))
  }

  /// Creates best-effort history using explicitly supplied process storage locations.
  public func makeActivityRecorder() -> any MovieFolderActivityServicing {
    do {
      let storeFactory = try locations.persistenceStoreFactory()
      return MovieFolderActivityRecorder(
        directory: try locations.appGroupContainerURL().appendingPathComponent("Activity"),
        notifier: SharedActivityChangeNotifier(),
        configurationRepository: try makeConfigurationRepository(),
        storeFactory: storeFactory)
    } catch {
      return UnavailableActivityService()
    }
  }

  /// Resolves testable process locations while always injecting shared privacy configuration.
  public func makeNetworkHistoryService() -> any MovieFolderNetworkHistoryServicing {
    do {
      let storeFactory = try locations.persistenceStoreFactory()
      return MovieFolderNetworkHistoryService(
        directory: try locations.appGroupContainerURL().appendingPathComponent("NetworkHistory"),
        configurationRepository: try makeConfigurationRepository(),
        notifier: SharedNetworkHistoryChangeNotifier(), storeFactory: storeFactory)
    } catch {
      return UnavailableNetworkHistoryService()
    }
  }

  /// Creates the production Keychain store or an access token-free acceptance-test store.
  /// - Returns: A Keychain store for normal launches and an isolated fixture store for acceptance launches.
  public func makeProviderAccessTokenStore() -> any ProviderAccessTokenStoring {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--acceptance-test") {
        return AcceptanceTestAccessTokenStore()
      }
    #endif

    return KeychainProviderAccessTokenStore(accessGroup: MovieFolderEnvironment.env(.groupIdentifier))
  }

  /// Opens only app-owned namespaces for an explicitly requested saved-data upgrade.
  /// - Returns: The shared migrator with backups isolated from normal collection-result cleanup.
  /// - Throws: Container, namespace or persistence access failures before migration begins.
  public func makeStorageMigrator() throws -> MovieFolderStorageMigrator {
    let container = try locations.appGroupContainerURL()
    let storeFactory = try locations.persistenceStoreFactory()

    return MovieFolderStorageMigrator(
      configurationStore: try storeFactory.makeStore(directory: container.appendingPathComponent("Settings")),
      collectionOutcomeStore: try CollectionProcessingStorageNamespace.open(in: container, using: storeFactory),
      backupStore: try storeFactory.makeStore(
        directory: container.appendingPathComponent("MigrationBackups"), maximumRecordBytes: 8 * 1024 * 1024),
      operationalContainer: container,
      processingLockStore: try storeFactory.makeStore(directory: container.appendingPathComponent("ProcessingLocks")))
  }

  /// Opens settings at the supplied process container location.
  public func makeConfigurationRepository() throws -> ConfigurationRepository {
    ConfigurationRepository(
      store: try locations.makePersistenceStore(
        directory: locations.appGroupContainerURL().appendingPathComponent("Settings")))
  }

  /// Opens recovery configuration at supplied process locations without clearing settings, results, or caches.
  public func makeProcessingRecoveryService() throws -> ProcessingRecoveryService {
    ProcessingRecoveryService(
      store: try locations.makePersistenceStore(
        directory: locations.appGroupContainerURL().appendingPathComponent("ProcessingRecovery"),
        maximumRecordBytes: 8_192))
  }

  /// Opens versioned outcomes after opening settings in the same supplied container.
  public func makeCollectionProcessingStore() throws -> CollectionProcessingStore {
    // Opening settings first preserves initial creation of the authorized App Group directory.
    let configurationRepository = try makeConfigurationRepository()
    let sharedContainer = try locations.appGroupContainerURL()

    return CollectionProcessingStore(
      store: try CollectionProcessingStorageNamespace.open(
        in: sharedContainer, using: try locations.persistenceStoreFactory()),
      configuration: configurationRepository,
      notifier: SharedCollectionProcessingStateChangeNotifier())
  }

  /// Opens private bookmarks beneath the supplied process Application Support directory.
  public func makePrivateAuthorizationStore() throws -> PersistenceStore {
    let support = try locations.applicationSupportURL()

    return try locations.makePersistenceStore(
      directory: support.appendingPathComponent("MovieFolderPosters/Authorization"))
  }
}

/// Sends committed collection processing state invalidations without carrying persisted state.
nonisolated private struct SharedCollectionProcessingStateChangeNotifier: CollectionProcessingStateChangeNotifying {
  /// Posts a change hint after the repository has released its persistence leases.
  func collectionProcessingStateDidChange() { MovieFolderEnvironment.notifyCollectionProcessingStateChanged() }
}

/// Announces committed activity changes without event data or storage paths.
nonisolated private struct SharedActivityChangeNotifier: MovieFolderActivityChangeNotifying {
  func movieFolderActivityDidChange() {
    DistributedNotificationCenter.default().postNotificationName(
      .movieFolderActivityChanged, object: .none, userInfo: .none, deliverImmediately: true)
  }
}

/// Keeps unavailable logging separate from all authorized product operations.
nonisolated private struct UnavailableActivityService: MovieFolderActivityServicing {
  /// Explicit history availability failure, with no sensitive error detail.
  private enum Failure: Error { case unavailable }

  /// Records only an operational diagnostic when history storage is unavailable.
  /// - Parameter event: Product event that cannot be written to history.
  /// - Returns: False because no history entry was committed.
  func record(_ event: MovieFolderActivityLogEvent) -> Bool {
    Logger(subsystem: "dag.fikios.MovieFolderPosters", category: "Activity")
      .error("Activity storage unavailable; the product operation result is unchanged")

    return false
  }

  /// Always reports unavailable history as a write failure.
  var hasObservedWriteFailure: Bool { true }
  /// Always throws the explicit unavailable-history failure.
  /// - Throws: `Failure.unavailable` for every request.
  func entries() throws -> [MovieFolderActivityLogEntry] { throw Failure.unavailable }
  /// Always throws because there is no available history store to clear.
  /// - Throws: `Failure.unavailable` for every request.
  func clear() throws { throw Failure.unavailable }
}

#if DEBUG
  /// Provides only a non-secret fixture token and never reaches the user's Keychain.
  nonisolated private struct AcceptanceTestAccessTokenStore: ProviderAccessTokenStoring {
    func read() throws -> String? { "acceptance-test-token" }
    func save(_ value: String) throws { throw ConfigurationError.invalidAccessToken }
    func remove() throws { throw ConfigurationError.invalidAccessToken }
  }
#endif

/// Publishes payload-free optional history changes after the committing service has released its accesses.
nonisolated private struct SharedNetworkHistoryChangeNotifier: MovieFolderNetworkHistoryChangeNotifying {
  func movieFolderNetworkHistoryDidChange() {
    DistributedNotificationCenter.default().postNotificationName(
      .movieFolderNetworkHistoryChanged, object: .none, userInfo: .none, deliverImmediately: true)
  }

  func movieFolderHistoryConfigurationDidChange() { MovieFolderEnvironment.notifyHistoryConfigurationChanged() }
}

/// Keeps optional unavailable network history separate from provider results.
nonisolated private struct UnavailableNetworkHistoryService: MovieFolderNetworkHistoryServicing {
  /// An explicit availability error without sensitive underlying details.
  private enum Failure: Error { case unavailable }
  var hasObservedWriteFailure: Bool { true }
  var isNetworkHistoryRecordingEnabled: Bool { get throws { throw Failure.unavailable } }
  func entries() throws -> [MovieFolderNetworkHistoryEntry] { throw Failure.unavailable }
  func clear() throws { throw Failure.unavailable }
  func setNetworkHistoryRecordingEnabled(_ enabled: Bool) throws { throw Failure.unavailable }
  func prepareNetworkHistoryRecording(collectionID: UUID?) -> UUID? { .none }
  func recordCompletedNetworkRequest(
    purpose: MovieNetworkRequestCategory, result: MovieNetworkRequestResult,
    completedAt: Date, expectedNetworkHistoryConfigurationRevision: UUID, collectionID: UUID?
  ) {}
}
