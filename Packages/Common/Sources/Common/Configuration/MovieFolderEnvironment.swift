import Foundation
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

  /// Announces a committed configuration change to other signed processes.
  /// - Parameter scheduleObservedCollections: Whether Finder should also schedule observed collections.
  public static func notifyConfigurationChanged(scheduleObservedCollections: Bool = true) {
    let userInfo: [AnyHashable: Any]? = scheduleObservedCollections ? .none : ["scheduleObservedCollections": false]
    DistributedNotificationCenter.default().postNotificationName(
      .movieFolderConfigurationChanged, object: .none,
      userInfo: userInfo, deliverImmediately: true)
  }

  /// Announces committed collection processing state writes so host summary views can reload persisted state.
  static func notifyCollectionProcessingStateChanged() {
    DistributedNotificationCenter.default().postNotificationName(
      .movieFolderCollectionProcessingStateChanged, object: .none,
      userInfo: .none, deliverImmediately: true)
  }
}

/// Resolves process-specific storage locations without granting access to their contents.
nonisolated public protocol MovieFolderApplicationStorageLocations: Sendable {
  /// Resolves the signed process's shared container or throws when unavailable.
  func appGroupContainerURL() throws -> URL
  /// Resolves this process's private Application Support location.
  func applicationSupportURL() throws -> URL
  /// Creates a store factory anchored to this process's explicit storage authorization, when one exists.
  func persistenceStoreFactory() throws -> PersistenceStoreFactory
}

extension MovieFolderApplicationStorageLocations {
  /// Uses ordinary persistence access when the location provider has no separate authorization root.
  public func persistenceStoreFactory() throws -> PersistenceStoreFactory { PersistenceStoreFactory() }

  /// Opens a store through this location provider's path authorization.
  func makePersistenceStore(directory: URL, maximumRecordBytes: Int? = .none) throws -> PersistenceStore {
    try persistenceStoreFactory().makeStore(directory: directory, maximumRecordBytes: maximumRecordBytes)
  }
}

/// Uses the calling process's existing entitlements and user-domain storage defaults.
nonisolated public struct MovieFolderSystemStorageLocations: MovieFolderApplicationStorageLocations {
  /// Creates process-specific storage locations from the current app identity and test arguments.
  public init() {}

  /// Resolves the signed process's App Group container or its validated acceptance-test container.
  public func appGroupContainerURL() throws -> URL { try MovieFolderEnvironment.appGroupContainerURL() }

  /// Resolves private application storage or the isolated acceptance-test private directory.
  public func applicationSupportURL() throws -> URL {
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

  /// Opens a store using the validated acceptance root when the Debug test launch requests it.
  public func makePersistenceStore(directory: URL, maximumRecordBytes: Int? = .none) throws -> PersistenceStore {
    try persistenceStoreFactory().makeStore(directory: directory, maximumRecordBytes: maximumRecordBytes)
  }

  /// Creates the instance-scoped authorization used by every store in this process.
  public func persistenceStoreFactory() throws -> PersistenceStoreFactory {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--acceptance-test") {
        guard let root = try MovieFolderEnvironment.acceptanceTestRoot() else {
          throw ConfigurationError.unavailableContainer
        }

        return PersistenceStoreFactory(trustedRoot: root)
      }
    #endif

    return PersistenceStoreFactory()
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
