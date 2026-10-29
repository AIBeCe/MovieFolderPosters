import Foundation
import Persistence

/// Persists validated shared settings under a cross-process access.
nonisolated public struct ConfigurationRepository: Sendable {
  /// The persistence record shared by all readers of this versioned payload.
  public static let recordKey = "directory-configuration-v1"
  /// The persistence store supplying cross-process leases and atomic record writes.
  let store: PersistenceStore

  /// Creates a settings repository backed by the caller's dedicated persistence namespace.
  /// - Parameter store: The store holding the versioned settings record and cross-process access.
  public init(store: PersistenceStore) { self.store = store }

  /// Reads the stored configuration under a access and validates its schema.
  /// - Returns: The validated configuration.
  /// - Throws: Configuration contention or validation errors, persistence failures, or errors propagated by a change.
  public func read() throws -> DirectoryConfiguration {
    let (configuration, persistenceAccess) = try readHoldingAccess()

    return withExtendedLifetime(persistenceAccess) { configuration }
  }

  /// Returns validated settings together with the access that keeps them stable.
  /// - Returns: The validated configuration and the access keeping that configuration stable.
  /// - Throws: Configuration contention or validation errors, persistence failures, or errors propagated by a change.
  public func readHoldingAccess() throws -> (DirectoryConfiguration, PersistenceAccess) {
    guard let persistenceAccess = try store.acquireAccess(for: Self.recordKey) else { throw ConfigurationError.busy }

    return (try read(persistenceAccess), persistenceAccess)
  }

  /// Reads persisted settings without manufacturing a generation for a missing record.
  /// - Returns: Optional validated settings and their exclusive access.
  /// - Throws: Busy, invalid settings, or persistence failures.
  public func readIfPresentHoldingAccess() throws -> (DirectoryConfiguration?, PersistenceAccess) {
    guard let persistenceAccess = try store.acquireAccess(for: Self.recordKey) else { throw ConfigurationError.busy }

    return (try readIfPresent(persistenceAccess), persistenceAccess)
  }

  /// Commits a credential generation before mutating Keychain under the same access.
  /// - Parameters:
  ///   - expectedRevision: Persisted generation, or absence captured on first run.
  ///   - afterCommit: Credential change; failure never rolls the settings generation back.
  /// - Throws: Cancellation, stale configuration, persistence, or credential change failures.
  public func updateCredential(expectedRevision: UUID?, afterCommit: () throws -> Void = {}) throws {
    let (saved, persistenceAccess) = try readIfPresentHoldingAccess()
    try Task.checkCancellation()
    guard saved?.credentialRevision == expectedRevision else { throw ConfigurationError.configurationChanged }
    var configuration = saved ?? DirectoryConfiguration()
    configuration.version = 6
    configuration.credentialRevision = UUID()
    try Self.validate(configuration)
    try persistenceAccess.write(JSONEncoder().encode(configuration))
    try withExtendedLifetime(persistenceAccess) { try afterCommit() }
  }

  /// Checks that the captured root and settings generation still authorize change.
  ///
  /// - Parameters:
  ///   - directory: The authorized collection root.
  ///   - expectedConfiguration: The settings generation captured before provider work began.
  /// - Returns: The settings access to retain until the validated change finishes.
  /// - Throws: Configuration contention or validation errors, persistence failures, or errors propagated by a change.
  public func configurationAccessForIconChange(
    for directory: MonitoredDirectory,
    childIdentity: String? = .none,
    requiresActiveCollection: Bool = true,
    expectedConfiguration: DirectoryConfiguration
  ) throws -> PersistenceAccess {
    let (currentConfiguration, persistenceAccess) = try readHoldingAccess()
    guard let configured = currentConfiguration.directories.first(where: { $0.id == directory.id }),
      configured.path == directory.path,
      configured.identity == directory.identity,
      configured.authorizationVersion == directory.authorizationVersion,
      configured.processingConfiguration.revision == directory.processingConfiguration.revision,
      expectedConfiguration.directories.first(where: { $0.id == directory.id })?.processingConfiguration.revision
        == directory.processingConfiguration.revision,
      currentConfiguration.credentialRevision == expectedConfiguration.credentialRevision,
      currentConfiguration.usesStubTMDbResponses == expectedConfiguration.usesStubTMDbResponses,
      currentConfiguration.posterAppearance == expectedConfiguration.posterAppearance,
      currentConfiguration.effectiveMovieMatchingConfiguration(for: configured)
        == expectedConfiguration.effectiveMovieMatchingConfiguration(for: directory)
    else {
      withExtendedLifetime(persistenceAccess) {}
      throw ConfigurationError.configurationChanged
    }

    guard !requiresActiveCollection || !configured.isPaused else {
      withExtendedLifetime(persistenceAccess) {}
      throw ConfigurationError.collectionPaused
    }
    if let childIdentity, requiresActiveCollection, configured.excludesFolder(identity: childIdentity) {
      withExtendedLifetime(persistenceAccess) {}
      throw ConfigurationError.folderExcluded
    }
    guard !currentConfiguration.findOverlappingDirectoryIDs().contains(directory.id) else {
      withExtendedLifetime(persistenceAccess) {}
      throw ConfigurationError.configurationChanged
    }

    return persistenceAccess
  }

  /// Retries short-lived configuration contention within a fixed attempt budget.
  ///
  /// - Parameter pause: The cancellable delay between bounded attempts at reading busy settings.
  /// - Returns: The validated configuration.
  /// - Throws: Configuration contention or validation errors, persistence failures, or errors propagated by a change.
  public func readWhenAvailable(
    pause: @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(20)) }
  ) async throws -> DirectoryConfiguration {
    for attempt in 0..<8 {
      try Task.checkCancellation()
      do { return try read() } catch ConfigurationError.busy {
        if attempt == 7 { throw ConfigurationError.busy }
        try await pause()
      }
    }
    throw ConfigurationError.busy
  }

  /// Validates and commits a settings change before running its post-commit action under the same access.
  ///
  /// - Parameters:
  ///   - change: The in-place configuration change performed before validation and commit.
  ///   - afterCommit: The action invoked only after persistence succeeds while the access remains held.
  /// - Throws: Configuration contention or validation errors, persistence failures, or errors propagated by a change.
  public func update(
    _ change: (inout DirectoryConfiguration) throws -> Void,
    afterCommit: () throws -> Void = {}
  ) throws {
    guard let persistenceAccess = try store.acquireAccess(for: Self.recordKey) else { throw ConfigurationError.busy }
    var configuration = try read(persistenceAccess)
    let previous = configuration
    try change(&configuration)
    try Self.validate(configuration)
    let previousRoots = Dictionary(uniqueKeysWithValues: previous.directories.map { ($0.id, $0) })
    let currentRoots = Dictionary(uniqueKeysWithValues: configuration.directories.map { ($0.id, $0) })
    let rootsChanged = previousRoots.keys != currentRoots.keys || currentRoots.contains { identifier, root in
      guard let previousRoot = previousRoots[identifier] else { return true }

      return previousRoot.usesPrivateHistory != root.usesPrivateHistory || previousRoot.path != root.path
        || previousRoot.identity != root.identity || previousRoot.authorizationVersion != root.authorizationVersion
    }
    if previous.isNetworkHistoryRecordingEnabled != configuration.isNetworkHistoryRecordingEnabled || rootsChanged {
      configuration.networkHistoryConfigurationRevision = UUID()
    }
    configuration.version = 6
    try persistenceAccess.write(JSONEncoder().encode(configuration))
    try withExtendedLifetime(persistenceAccess) { try afterCommit() }
  }

  /// Removes one collection and returns historical evidence only after the configuration commit succeeds.
  /// - Parameter identifier: Stable configured collection identity selected for removal.
  /// - Returns: Repository-minted name and privacy evidence from the committed removal.
  /// - Throws: Missing collection, configuration contention, cancellation, or persistence failures.
  public func removeCollection(_ identifier: UUID) throws -> CommittedCollectionRemoval {
    try Task.checkCancellation()
    var removedDirectory: MonitoredDirectory?
    try update { configuration in
      guard let index = configuration.directories.firstIndex(where: { $0.id == identifier }) else {
        throw ConfigurationError.directoryNotFound
      }

      removedDirectory = configuration.directories.remove(at: index)
    }

    guard let removedDirectory else { throw ConfigurationError.directoryNotFound }

    return CommittedCollectionRemoval(directory: removedDirectory)
  }

  /// Reads the stored configuration under a access and validates its schema.
  ///
  /// - Parameter persistenceAccess: The already-held persistence access used throughout this operation.
  /// - Returns: The validated configuration.
  /// - Throws: Configuration contention or validation errors, persistence failures, or errors propagated by a change.
  private func read(_ persistenceAccess: PersistenceAccess) throws -> DirectoryConfiguration {
    try readIfPresent(persistenceAccess) ?? DirectoryConfiguration()
  }

  /// Decodes only a genuinely persisted record, preserving absence for conditional mutations.
  /// - Parameter persistenceAccess: The exclusive settings access.
  /// - Returns: Validated settings or absence.
  /// - Throws: Persistence or schema failures.
  private func readIfPresent(_ persistenceAccess: PersistenceAccess) throws -> DirectoryConfiguration? {
    let storedData: Data?
    do { storedData = try persistenceAccess.read() } catch {
      throw MovieFolderStorageMigrationError.storageUnavailable(record: .settings)
    }

    guard let data = storedData else { return .none }

    let configuration: DirectoryConfiguration
    do {
      configuration = try JSONDecoder().decode(DirectoryConfiguration.self, from: data)
      try Self.validate(configuration)
    } catch let error as MovieFolderStorageMigrationError {
      throw error
    } catch {
      throw MovieFolderStorageMigrationError.invalidRecord(record: .settings)
    }

    return configuration
  }

  /// Rejects unsupported versions, duplicate roots, and malformed authorization records.
  ///
  /// - Parameter configuration: The complete settings payload to validate or retain.
  /// - Throws: Configuration contention or validation errors, persistence failures, or errors propagated by a change.
  static func validate(_ configuration: DirectoryConfiguration) throws {
    guard configuration.version == 6,
      Set(configuration.directories.map(\.id)).count == configuration.directories.count,
      Set(configuration.directories.map(\.path)).count == configuration.directories.count,
      configuration.directories.allSatisfy({
        $0.path.hasPrefix("/") && !$0.transferBookmark.isEmpty
          && Set($0.processingConfiguration.excludedFolders.map(\.identity)).count
            == $0.processingConfiguration.excludedFolders.count
          && $0.processingConfiguration.excludedFolders.allSatisfy {
            !$0.identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              && !$0.lastKnownName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          }
      })
    else {
      throw ConfigurationError.invalidConfiguration
    }
  }
}
