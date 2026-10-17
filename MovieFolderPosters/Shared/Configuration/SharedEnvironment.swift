import Foundation
import Persistence

/// Resolves the host and extension storage locations and configuration notification.
nonisolated enum SharedEnvironment {
  /// The App Group shared by the signed host and Finder extension.
  static let groupIdentifier = "group.dag.fikios.MovieFolderPosters"
  /// The distributed notification announcing committed settings changes.
  static let configurationChanged = Notification.Name("dag.fikios.MovieFolderPosters.ConfigurationChanged")

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
}
