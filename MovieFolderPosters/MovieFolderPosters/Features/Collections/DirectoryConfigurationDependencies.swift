import FileSystem
import Foundation
import MovieFolderCommon
import Persistence

/// Notifies shared components after configuration has been persisted.
nonisolated protocol ConfigurationChangeNotifying: Sendable {
  /// Informs shared app components that persisted configuration changed.
  func configurationDidChange()
  /// Refreshes collection names without cancelling in-flight Finder processing.
  func collectionPresentationDidChange()
}

nonisolated extension ConfigurationChangeNotifying {
  /// Retains compatibility for observers without separate presentation invalidations.
  func collectionPresentationDidChange() {}
}

/// Sends configuration-change notifications through the shared environment.
nonisolated struct SharedConfigurationChangeNotifier: ConfigurationChangeNotifying {
  /// Publishes a process-wide configuration change notification.
  func configurationDidChange() { MovieFolderEnvironment.notifyConfigurationChanged() }
  /// Publishes presentation-only changes to interested host interfaces.
  func collectionPresentationDidChange() {
    DistributedNotificationCenter.default().postNotificationName(
      .movieFolderCollectionPresentationChanged, object: .none, userInfo: .none, deliverImmediately: true)
  }
}

/// Creates and resolves security-scoped bookmarks for configured directories.
nonisolated protocol DirectoryAuthorizationProviding: Sendable {
  /// Resolves a security bookmark and validates its expected directory identity.
  /// - Parameters:
  ///   - bookmark: The persisted security-scoped bookmark.
  ///   - expectedIdentity: Saved identity used to reject folder replacement.
  /// - Returns: Directory access retained for the caller's work.
  /// - Throws: A directory access error when the bookmark is invalid or stale.
  func acquireAccess(bookmark: Data, expectedIdentity: String?) throws -> AuthorizedDirectoryAccess
  /// Creates a security bookmark for the selected folder.
  /// - Parameter directory: The folder for which access should be persisted.
  /// - Returns: Bookmark data suitable for secure persistence.
  /// - Throws: A directory access error if bookmark creation fails.
  func makeBookmark(for directory: URL) throws -> Data
}

/// Uses FileSystemService to resolve and create security-scoped directory bookmarks.
nonisolated struct SecurityScopedDirectoryAuthorization: DirectoryAuthorizationProviding {
  /// Resolves a security-scoped bookmark and checks the saved folder identity.
  func acquireAccess(bookmark: Data, expectedIdentity: String?) throws -> AuthorizedDirectoryAccess {
    try FileSystemService().acquireDirectoryAccess(
      bookmark: bookmark, securityScoped: true, expectedIdentity: expectedIdentity)
  }
  /// Creates a security-scoped bookmark for later access.
  func makeBookmark(for directory: URL) throws -> Data { try FileSystemService().makeDirectoryBookmark(for: directory) }
}

/// Removes outcome records no longer referenced by committed configuration.
nonisolated protocol CollectionProcessingCleaning: Sendable {
  /// Prunes orphaned records while retaining the store's configuration fencing.
  func pruneToConfiguredRoots() throws -> Set<String>
}

extension CollectionProcessingStore: CollectionProcessingCleaning {}

/// Creates the persistence key for a collection's authorization bookmark.
nonisolated struct DirectoryAuthorizationKeyFactory {
  /// Returns the key associated with the collection's current authorization generation.
  func key(for directory: MonitoredDirectory) -> String {
    "host-\(directory.id)-\(directory.authorizationVersion)"
  }
}

/// Resolves saved bookmark and filesystem evidence for one configured collection.
nonisolated struct ConfiguredDirectoryInspector {
  /// Persistence store containing the collection's bookmark record.
  private let authorizations: PersistenceStore
  /// Resolves validated bookmarks while retaining scoped directory access.
  private let authorization: any DirectoryAuthorizationProviding
  /// Reads filesystem identity and creates transferable bookmarks.
  private let fileSystem: FileSystemService
  /// Creates the key used to load this directory's persisted authorization bookmark.
  private let authorizationKeys: DirectoryAuthorizationKeyFactory

  /// Creates an inspector using the stores and filesystem service owned by configuration.
  /// - Parameters:
  ///   - authorizations: Store containing bookmark records.
  ///   - authorization: Resolver for security-scoped bookmarks.
  ///   - fileSystem: Filesystem service for identity checks and bookmark creation.
  init(
    authorizations: PersistenceStore, authorization: any DirectoryAuthorizationProviding,
    fileSystem: FileSystemService, authorizationKeys: DirectoryAuthorizationKeyFactory = .init()
  ) {
    self.authorizations = authorizations
    self.authorization = authorization
    self.fileSystem = fileSystem
    self.authorizationKeys = authorizationKeys
  }

  /// Reads a collection's current availability and any safe identity-backed metadata refresh.
  /// - Parameter directory: The saved root whose identity must still match.
  /// - Returns: Availability and any safely refreshed path or bookmark metadata.
  func inspect(
    _ directory: MonitoredDirectory
  ) -> (availability: MovieFolderCommon.DirectoryAvailability, refreshed: MonitoredDirectory?) {
    var refreshed: MonitoredDirectory?
    let availability: MovieFolderCommon.DirectoryAvailability
    do {
      let inspection = try inspectAuthorizedDirectory(directory)
      availability = inspection.availability
      refreshed = inspection.refreshed
    } catch ConfigurationError.busy {
      availability = .checkUnavailable
    } catch DirectoryAccessError.identityChanged {
      availability = .identityChanged
    } catch DirectoryAccessError.staleBookmark {
      let evidence = fileSystem.inspectDirectory(
        at: URL(fileURLWithPath: directory.path),
        expectedIdentity: directory.identity, expectedVolumePath: directory.volumePath)
      availability = directory.identity != .none
        && [.missing, .disconnected, .identityChanged].contains(evidence.state)
        ? directoryAvailability(for: evidence.state) : .reauthorizationRequired
    } catch {
      let evidence = fileSystem.inspectDirectory(
        at: URL(fileURLWithPath: directory.path),
        expectedIdentity: directory.identity, expectedVolumePath: directory.volumePath)
      if [.missing, .disconnected, .identityChanged].contains(evidence.state) {
        availability = directoryAvailability(for: evidence.state)
      } else if case DirectoryAccessError.accessDenied = error {
        availability = .reauthorizationRequired
      } else {
        availability = .unavailable
      }
    }

    return (availability, refreshed)
  }

  /// Refreshes authorized metadata while keeping both access and the bookmark access alive.
  /// - Parameter directory: Root requiring matching persistent identity.
  /// - Returns: Availability and any validated metadata refresh.
  /// - Throws: Authorization, identity, bookmark, or persistence errors.
  private func inspectAuthorizedDirectory(
    _ directory: MonitoredDirectory
  ) throws -> (availability: MovieFolderCommon.DirectoryAvailability, refreshed: MonitoredDirectory?) {
    var refreshed: MonitoredDirectory?
    guard let persistenceAccess = try authorizations.acquireAccess(
      for: authorizationKeys.key(for: directory)) else {
      throw ConfigurationError.busy
    }
    guard let bookmark = try persistenceAccess.read() else { throw DirectoryAccessError.staleBookmark }
    let directoryAccess = try authorization.acquireAccess(bookmark: bookmark, expectedIdentity: directory.identity)
    let evidence = fileSystem.inspectDirectory(at: directoryAccess.url, expectedIdentity: directory.identity)
    var updated = directory
    let resolvedPath = directoryAccess.url.resolvingSymlinksInPath().standardizedFileURL.path
    if resolvedPath != directory.path, directory.identity == .none { throw DirectoryAccessError.staleBookmark }
    if let identity = evidence.identity, evidence.state != .identityChanged {
      updated.path = resolvedPath
      updated.identity = identity
      updated.volumePath = evidence.volumePath ?? directory.volumePath
      updated.transferBookmark = try fileSystem.makeTransferBookmark(for: directoryAccess.url)
      if updated.path != directory.path {
        try persistenceAccess.write(authorization.makeBookmark(for: directoryAccess.url))
      }
      refreshed = updated == directory ? .none : updated
    }
    withExtendedLifetime(persistenceAccess) { withExtendedLifetime(directoryAccess) {} }

    return (directoryAvailability(for: evidence.state), refreshed)
  }

  /// Maps filesystem readiness evidence to the collection's displayed availability.
  private func directoryAvailability(
    for state: FileSystem.DirectoryAvailability
  ) -> MovieFolderCommon.DirectoryAvailability {
    switch state {
    case .accessible: .available
    case .disconnected: .disconnected
    case .missing: .missing
    case .accessDenied: .reauthorizationRequired
    case .readOnly: .readOnly
    case .unsupported: .unsupported
    case .identityChanged: .identityChanged
    case .unknown: .compatibilityUnknown
    }
  }

}
