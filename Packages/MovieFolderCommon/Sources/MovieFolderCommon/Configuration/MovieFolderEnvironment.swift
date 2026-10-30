import Foundation
import Network
import OSLog
import Persistence

/// Resolves storage and notifications in the calling host or Finder extension process.
///
/// App Group and private authorization locations use the calling process's identity and entitlements.
/// Importing this module grants no filesystem authorization or cross-process runtime ownership.
nonisolated public enum MovieFolderEnvironment {
  /// Stores configuration values without exposing their storage as public API.
  public enum EnvironmentKey: String {
    /// The App Group shared by the signed host and Finder extension.
    case groupIdentifier = "group.dag.fikios.MovieFolderPosters"

    var value: String { rawValue }
  }

  /// Resolves an immutable configuration value selected from the supported keys.
  /// - Parameter key: The configuration value requested by the caller.
  /// - Returns: The configured string value, independent of actor or instance state.
  public static func env(_ key: EnvironmentKey) -> String {
    key.value
  }

  /// Creates a best-effort activity service without making logging a startup requirement.
  /// - Returns: A shared-container recorder, or an unavailable service when the caller cannot resolve its container.
  public static func makeActivityRecorder() -> any MovieFolderActivityServicing {
    makeActivityRecorder(locations: SystemMovieFolderStorageLocations())
  }

  /// Creates best-effort history using explicitly supplied process storage locations.
  static func makeActivityRecorder(locations: any MovieFolderStorageLocations) -> any MovieFolderActivityServicing {
    do {
      return MovieFolderActivityRecorder(
        directory: try locations.appGroupContainerURL().appendingPathComponent("Activity"),
        notifier: SharedActivityChangeNotifier(),
        configurationRepository: try makeConfigurationRepository(locations: locations))
    } catch {
      return UnavailableActivityService()
    }
  }

  /// Creates optional request history without making it a startup or provider requirement.
  /// - Returns: A shared privacy-enforcing service, or an explicit unavailable fallback.
  public static func makeNetworkHistoryService() -> any MovieFolderNetworkHistoryServicing {
    makeNetworkHistoryService(locations: SystemMovieFolderStorageLocations())
  }

  /// Resolves testable process locations while always injecting shared privacy configuration.
  static func makeNetworkHistoryService(
    locations: any MovieFolderStorageLocations
  ) -> any MovieFolderNetworkHistoryServicing {
    do {
      return MovieFolderNetworkHistoryService(
        directory: try locations.appGroupContainerURL().appendingPathComponent("NetworkHistory"),
        configurationRepository: try makeConfigurationRepository(locations: locations),
        notifier: SharedNetworkHistoryChangeNotifier())
    } catch {
      return UnavailableNetworkHistoryService()
    }
  }

  /// Announces committed history-only privacy settings after repository accesses are released.
  public static func notifyHistoryConfigurationChanged() {
    DistributedNotificationCenter.default().postNotificationName(
      .movieFolderHistoryConfigurationChanged, object: .none, userInfo: .none, deliverImmediately: true)
  }

  /// Resolves the signed process's shared App Group container.
  ///
  /// Returning a URL does not verify filesystem access; callers must handle access failures when using it.
  /// - Returns: The App Group URL resolved using the calling process's entitlements.
  /// - Throws: ConfigurationError.unavailableContainer when that process cannot resolve the App Group.
  public static func appGroupContainerURL() throws -> URL {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--acceptance-test") {
        guard let root = try acceptanceTestRoot() else { throw ConfigurationError.unavailableContainer }
        let shared = root.appendingPathComponent("Shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)

        return shared
      }
    #endif

    guard
      let url = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: MovieFolderEnvironment.env(.groupIdentifier)
      )
    else { throw ConfigurationError.unavailableContainer }

    return url
  }

  /// Creates the production Keychain store or a credential-free acceptance-test store.
  /// - Returns: A Keychain store for normal launches and an isolated fixture store for acceptance launches.
  public static func makeCredentialStore() -> any CredentialStoring {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--acceptance-test") {
        return AcceptanceTestCredentialStore()
      }
    #endif

    return KeychainCredentialStore(accessGroup: MovieFolderEnvironment.env(.groupIdentifier))
  }

  /// Opens the settings repository in the shared container.
  /// - Returns: The shared configuration repository backed by its settings persistence store.
  /// - Throws: An unavailable App Group container or a failure creating the required persistence directory.
  public static func makeConfigurationRepository() throws -> ConfigurationRepository {
    try makeConfigurationRepository(locations: SystemMovieFolderStorageLocations())
  }

  /// Opens only app-owned namespaces for an explicitly requested saved-data upgrade.
  /// - Returns: The shared migrator with backups isolated from normal collection-result cleanup.
  /// - Throws: Container, namespace or persistence access failures before migration begins.
  public static func makeStorageMigrator() throws -> MovieFolderStorageMigrator {
    let container = try MovieFolderEnvironment.appGroupContainerURL()

    return MovieFolderStorageMigrator(
      configurationStore: try PersistenceStore(directory: container.appendingPathComponent("Settings")),
      collectionOutcomeStore: try CollectionProcessingStorageNamespace.open(in: container),
      backupStore: try PersistenceStore(
        directory: container.appendingPathComponent("MigrationBackups"), maximumRecordBytes: 8 * 1024 * 1024),
      operationalContainer: container,
      coordinationStore: try PersistenceStore(directory: container.appendingPathComponent("ProcessingLocks")))
  }

  /// Opens settings at the supplied process container location.
  static func makeConfigurationRepository(
    locations: any MovieFolderStorageLocations
  ) throws -> ConfigurationRepository {
    try ConfigurationRepository(
      store: PersistenceStore(directory: locations.appGroupContainerURL().appendingPathComponent("Settings")))
  }

  /// Opens recovery mode and provider configuration in their dedicated bounded shared App Group namespace.
  /// - Returns: A service shared by host and Finder processes, independent of collection roots.
  /// - Throws: An unavailable container or a failure opening the recovery persistence namespace.
  public static func makeProcessingRecoveryService() throws -> ProcessingRecoveryService {
    try makeProcessingRecoveryService(locations: SystemMovieFolderStorageLocations())
  }

  /// Opens recovery configuration at supplied process locations without clearing settings, results, or caches.
  static func makeProcessingRecoveryService(
    locations: any MovieFolderStorageLocations
  ) throws -> ProcessingRecoveryService {
    ProcessingRecoveryService(
      store: try PersistenceStore(
        directory: locations.appGroupContainerURL().appendingPathComponent("ProcessingRecovery"),
        maximumRecordBytes: 8_192))
  }

  /// Opens the versioned collection processing state repository in its dedicated App Group namespace.
  /// - Returns: A state repository using the current shared directory and payload-free change notifier.
  /// - Throws: An unavailable container, required offline migration, or a persistence directory failure.
  public static func makeCollectionProcessingStore() throws -> CollectionProcessingStore {
    try makeCollectionProcessingStore(locations: SystemMovieFolderStorageLocations())
  }

  /// Opens versioned outcomes after opening settings in the same supplied container.
  static func makeCollectionProcessingStore(
    locations: any MovieFolderStorageLocations
  ) throws -> CollectionProcessingStore {
    // Opening settings first preserves initial creation of the authorized App Group directory.
    let configurationRepository = try makeConfigurationRepository(locations: locations)
    let sharedContainer = try locations.appGroupContainerURL()

    return CollectionProcessingStore(
      store: try CollectionProcessingStorageNamespace.open(in: sharedContainer),
      configuration: configurationRepository,
      notifier: SharedCollectionProcessingStateChangeNotifier())
  }

  /// Opens this process's private security-scoped authorization store.
  /// - Returns: The private bookmark store belonging to this signed process.
  /// - Throws: A failure resolving Application Support or creating the private persistence directory.
  public static func makePrivateAuthorizationStore() throws -> PersistenceStore {
    try makePrivateAuthorizationStore(locations: SystemMovieFolderStorageLocations())
  }

  /// Opens private bookmarks beneath the supplied process Application Support directory.
  static func makePrivateAuthorizationStore(locations: any MovieFolderStorageLocations) throws -> PersistenceStore {
    let support = try locations.applicationSupportURL()

    return try PersistenceStore(directory: support.appendingPathComponent("MovieFolderPosters/Authorization"))
  }

  /// Announces a committed configuration change to other signed processes.
  public static func notifyConfigurationChanged() {
    DistributedNotificationCenter.default().postNotificationName(
      .movieFolderConfigurationChanged, object: .none,
      userInfo: .none, deliverImmediately: true)
  }

  /// Announces committed collection processing state writes so host summary views can reload persisted state.
  static func notifyCollectionProcessingStateChanged() {
    DistributedNotificationCenter.default().postNotificationName(
      .movieFolderCollectionProcessingStateChanged, object: .none,
      userInfo: .none, deliverImmediately: true)
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

/// Resolves process-specific storage locations without granting access to their contents.
nonisolated protocol MovieFolderStorageLocations: Sendable {
  /// Resolves the signed process's shared container or throws when unavailable.
  func appGroupContainerURL() throws -> URL
  /// Resolves this process's private Application Support location.
  func applicationSupportURL() throws -> URL
}

/// Uses the calling process's existing entitlements and user-domain storage defaults.
nonisolated private struct SystemMovieFolderStorageLocations: MovieFolderStorageLocations {
  func appGroupContainerURL() throws -> URL { try MovieFolderEnvironment.appGroupContainerURL() }
  func applicationSupportURL() throws -> URL {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--acceptance-test") {
        guard let root = try MovieFolderEnvironment.acceptanceTestRoot() else {
          throw ConfigurationError.unavailableContainer
        }
        let privateStorage = root.appendingPathComponent("Private", isDirectory: true)
        try FileManager.default.createDirectory(at: privateStorage, withIntermediateDirectories: true)

        return privateStorage
      }
    #endif

    return try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: .none, create: true)
  }
}

extension MovieFolderEnvironment {
  /// Resolves the pre-created temporary directory supplied by the XCUITest runner.
  /// - Returns: The isolated acceptance root when the launch argument and environment are valid.
  /// - Throws: `ConfigurationError.unavailableContainer` for absent, non-temporary, or invalid paths.
  #if DEBUG
    fileprivate static func acceptanceTestRoot() throws -> URL? {
      guard ProcessInfo.processInfo.arguments.contains("--acceptance-test") else { return .none }
      guard let path = ProcessInfo.processInfo.environment["MOVIEFOLDER_ACCEPTANCE_TEST_ROOT"] else {
        throw ConfigurationError.unavailableContainer
      }
      let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
      let temporaryParent = URL(
        fileURLWithPath: "/private/tmp/MovieFolderPostersAcceptance", isDirectory: true).standardizedFileURL
      let resolvedRoot = root.resolvingSymlinksInPath()
      let resolvedParent = temporaryParent.resolvingSymlinksInPath()
      let isDirectChild = root.deletingLastPathComponent() == temporaryParent
      let isResolvedDirectChild = resolvedRoot.deletingLastPathComponent() == resolvedParent

      guard root.isFileURL, isDirectChild, isResolvedDirectChild,
        UUID(uuidString: root.lastPathComponent) != .none
      else { throw ConfigurationError.unavailableContainer }

      var isDirectory = ObjCBool(false)
      guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw ConfigurationError.unavailableContainer
      }

      return root
    }
  #endif
}

#if DEBUG
  /// Provides only a non-secret fixture token and never reaches the user's Keychain.
  nonisolated private struct AcceptanceTestCredentialStore: CredentialStoring {
    func read() throws -> String? { "acceptance-test-token" }
    func save(_ value: String) throws { throw ConfigurationError.invalidCredential }
    func remove() throws { throw ConfigurationError.invalidCredential }
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
    purpose: Network.TMDbRequestCategory, result: Network.TMDbRequestResult,
    completedAt: Date, expectedNetworkHistoryConfigurationRevision: UUID, collectionID: UUID?
  ) {}
}
