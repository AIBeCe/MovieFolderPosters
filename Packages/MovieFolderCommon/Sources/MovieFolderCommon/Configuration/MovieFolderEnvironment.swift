import Foundation
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
        notifier: SharedActivityChangeNotifier())
    } catch {
      return UnavailableActivityService()
    }
  }

  /// Resolves the signed process's shared App Group container.
  ///
  /// Returning a URL does not verify filesystem access; callers must handle access failures when using it.
  /// - Returns: The App Group URL resolved using the calling process's entitlements.
  /// - Throws: ConfigurationError.unavailableContainer when that process cannot resolve the App Group.
  public static func appGroupContainerURL() throws -> URL {
    guard
      let url = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: MovieFolderEnvironment.env(.groupIdentifier)
      )
    else { throw ConfigurationError.unavailableContainer }

    return url
  }

  /// Opens the settings repository in the shared container.
  /// - Returns: The shared configuration repository backed by its settings persistence store.
  /// - Throws: An unavailable App Group container or a failure creating the required persistence directory.
  public static func makeConfigurationRepository() throws -> ConfigurationRepository {
    try makeConfigurationRepository(locations: SystemMovieFolderStorageLocations())
  }

  /// Opens settings at the supplied process container location.
  static func makeConfigurationRepository(
    locations: any MovieFolderStorageLocations
  ) throws -> ConfigurationRepository {
    try ConfigurationRepository(
      store: PersistenceStore(directory: locations.appGroupContainerURL().appendingPathComponent("Settings")))
  }

  /// Opens recovery mode and provider policy in their dedicated bounded shared App Group namespace.
  /// - Returns: A service shared by host and Finder processes, independent of collection roots.
  /// - Throws: An unavailable container or a failure opening the recovery persistence namespace.
  public static func makeProcessingRecoveryService() throws -> ProcessingRecoveryService {
    try makeProcessingRecoveryService(locations: SystemMovieFolderStorageLocations())
  }

  /// Opens recovery policy at supplied process locations without clearing settings, results, or caches.
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
  func record(_ event: MovieFolderActivityEvent) -> Bool {
    Logger(subsystem: "dag.fikios.MovieFolderPosters", category: "Activity")
      .error("Activity storage unavailable; the product operation result is unchanged")

    return false
  }

  /// Always reports unavailable history as a write failure.
  var hasObservedWriteFailure: Bool { true }
  /// Always throws the explicit unavailable-history failure.
  /// - Throws: `Failure.unavailable` for every request.
  func entries() throws -> [MovieFolderActivityEntry] { throw Failure.unavailable }
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
    try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: .none, create: true)
  }
}
