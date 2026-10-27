import FileSystem
import Foundation
import MovieFolderCommon
import Persistence

/// Retains the host grant independently of processing or child admission.
nonisolated struct MovieFolderAuthorizedRoot: Sendable {
  /// Saved settings used while acquiring this grant.
  let configuration: DirectoryConfiguration
  /// Saved collection and authorization generation.
  let directory: MonitoredDirectory
  /// Authorized filesystem location.
  let root: URL
  /// Private grant access retained through the operation.
  let authorizationAccess: PersistenceAccess
  /// Security scope retained through the operation.
  let rootAccess: DirectoryAccess
  /// Physical root identity captured after access acquisition.
  let rootIdentity: String
}

/// Acquires only the existing host bookmark/root authorization, without processing admission.
nonisolated struct MovieFolderAuthorization: Sendable {
  /// Required host storage boundary, retained strongly.
  let environment: any MoviePosterActionEnvironment
  /// Filesystem authorization adapter.
  private let fileSystem = FileSystemService()

  /// Retains the host storage boundary for the complete acquisition.
  init(environment: any MoviePosterActionEnvironment) { self.environment = environment }

  /// Acquires the configured root while preserving private-bookmark recovery.
  /// - Throws: Existing configuration, grant, identity, or cancellation failures.
  @concurrent func acquire(rootID: UUID) async throws -> MovieFolderAuthorizedRoot {
    let repository = try environment.makeConfigurationRepository()
    let configuration = try await repository.readWhenAvailable()

    guard let directory = configuration.directories.first(where: { $0.id == rootID }) else {
      throw MoviePosterActionServiceError.directoryNotConfigured
    }

    guard !configuration.findOverlappingDirectoryIDs().contains(directory.id) else {
      throw MoviePosterActionServiceError.directoryUnavailable
    }

    let authorizationStore = try environment.makePrivateAuthorizationStore()
    let authorizationKey = "host-\(directory.id)-\(directory.authorizationVersion)"

    guard let authorizationAccess = try authorizationStore.acquireAccess(for: authorizationKey) else {
      throw ConfigurationError.busy
    }

    let rootAccess: DirectoryAccess
    if let bookmark = try authorizationAccess.read(),
      let persisted = try? fileSystem.acquireDirectoryAccess(
        bookmark: bookmark, securityScoped: true,
        expectedIdentity: directory.identity) {
      rootAccess = persisted
    } else {
      rootAccess = try fileSystem.acquireDirectoryAccess(
        bookmark: directory.transferBookmark,
        securityScoped: false, expectedIdentity: directory.identity)
      try Task.checkCancellation()
      try authorizationAccess.write(environment.makeDirectoryBookmark(for: rootAccess.url))
    }

    guard rootAccess.url.standardizedFileURL.path == directory.path else {
      throw MoviePosterActionServiceError.directoryUnavailable
    }

    try Task.checkCancellation()

    return MovieFolderAuthorizedRoot(configuration: configuration, directory: directory,
      root: rootAccess.url, authorizationAccess: authorizationAccess, rootAccess: rootAccess,
      rootIdentity: try fileSystem.persistentDirectoryIdentity(at: rootAccess.url))
  }
}
