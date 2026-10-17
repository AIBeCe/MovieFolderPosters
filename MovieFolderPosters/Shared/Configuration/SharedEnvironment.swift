import Foundation
import Persistence

/// Resolves the host and extension storage locations and configuration notification.
nonisolated enum SharedEnvironment {
  /// The App Group shared by the signed host and Finder extension.
  static let groupIdentifier = "group.dag.fikios.MovieFolderPosters"
  /// The distributed notification announcing committed settings changes.
  static let configurationChanged = Notification.Name("dag.fikios.MovieFolderPosters.ConfigurationChanged")
  /// The distributed notification announcing committed processing outcome changes.
  static let collectionProcessingChanged = Notification.Name(
    "dag.fikios.MovieFolderPosters.CollectionOutcomesChanged")

  /// Resolves the signed process's shared App Group container.
  /// - Returns: The resolved storage URL.
  /// - Throws: An unavailable App Group container or a failure creating the required persistence directory.
  static func container() throws -> URL {
    guard
      let url = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: groupIdentifier
      )
    else { throw ConfigurationError.unavailableContainer }

    return url
  }

  /// Opens the settings repository in the shared container.
  /// - Returns: The shared configuration repository backed by its settings persistence store.
  /// - Throws: An unavailable App Group container or a failure creating the required persistence directory.
  static func repository() throws -> ConfigurationRepository {
    try ConfigurationRepository(store: PersistenceStore(directory: container().appendingPathComponent("Settings")))
  }

  /// Opens the versioned collection processing state repository in its dedicated App Group namespace.
  static func makeCollectionProcessingStore() throws -> CollectionProcessingStore {
    let sharedContainer = try container()
    return CollectionProcessingStore(
      store: try PersistenceStore(
        directory: sharedContainer.appendingPathComponent("Outcomes"),
        maximumRecordBytes: 8 * 1024 * 1024),
      configuration: try repository(),
      notifier: SharedCollectionProcessingChangeNotifier())
  }

  /// Opens this process's private security-scoped authorization store.
  /// - Returns: The private bookmark store belonging to this signed process.
  /// - Throws: An unavailable App Group container or a failure creating the required persistence directory.
  static func privateAuthorizations() throws -> PersistenceStore {
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    )

    return try PersistenceStore(directory: support.appendingPathComponent("MovieFolderPosters/Authorization"))
  }

  /// Announces a committed configuration change to other signed processes.
  static func notifyConfigurationChanged() {
    DistributedNotificationCenter.default().postNotificationName(
      configurationChanged, object: nil,
      userInfo: nil, deliverImmediately: true)
  }

  /// Announces committed outcome writes so host summary views can reload persisted snapshots.
  static func notifyCollectionProcessingChanged() {
    DistributedNotificationCenter.default().postNotificationName(
      collectionProcessingChanged, object: nil,
      userInfo: nil, deliverImmediately: true)
  }
}

/// Sends committed outcome invalidations to host processes without carrying result data.
nonisolated struct SharedCollectionProcessingChangeNotifier: CollectionProcessingChangeNotifying {
  /// Posts a change hint after the repository has released its persistence leases.
  func collectionProcessingDidChange() { SharedEnvironment.notifyCollectionProcessingChanged() }
}
