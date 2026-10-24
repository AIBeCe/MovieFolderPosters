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
    let (configuration, access) = try readHoldingAccess()

    return withExtendedLifetime(access) { configuration }
  }

  /// Returns validated settings together with the access that keeps them stable.
  /// - Returns: The validated configuration and the access keeping that configuration stable.
  /// - Throws: Configuration contention or validation errors, persistence failures, or errors propagated by a change.
  public func readHoldingAccess() throws -> (DirectoryConfiguration, PersistenceAccess) {
    guard let access = try store.acquireAccess(for: Self.recordKey) else { throw ConfigurationError.busy }

    return (try read(access), access)
  }

  /// Reads persisted settings without manufacturing a generation for a missing record.
  /// - Returns: Optional validated settings and their exclusive access.
  /// - Throws: Busy, invalid settings, or persistence failures.
  public func readIfPresentHoldingAccess() throws -> (DirectoryConfiguration?, PersistenceAccess) {
    guard let access = try store.acquireAccess(for: Self.recordKey) else { throw ConfigurationError.busy }

    return (try readIfPresent(access), access)
  }

  /// Commits a credential generation before mutating Keychain under the same access.
  /// - Parameters:
  ///   - expectedRevision: Persisted generation, or absence captured on first run.
  ///   - afterCommit: Credential change; failure never rolls the settings generation back.
  /// - Throws: Cancellation, stale configuration, persistence, or credential change failures.
  public func updateCredential(expectedRevision: UUID?, afterCommit: () throws -> Void = {}) throws {
    let (saved, access) = try readIfPresentHoldingAccess()
    try Task.checkCancellation()
    guard saved?.credentialRevision == expectedRevision else { throw ConfigurationError.configurationChanged }
    var configuration = saved ?? DirectoryConfiguration()
    configuration.version = 3
    configuration.credentialRevision = UUID()
    try validate(configuration)
    try access.write(JSONEncoder().encode(configuration))
    try withExtendedLifetime(access) { try afterCommit() }
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
    let (current, access) = try readHoldingAccess()
    guard let configured = current.directories.first(where: { $0.id == directory.id }),
      configured.path == directory.path,
      configured.identity == directory.identity,
      configured.authorizationVersion == directory.authorizationVersion,
      configured.processingConfiguration.revision == directory.processingConfiguration.revision,
      expectedConfiguration.directories.first(where: { $0.id == directory.id })?.processingConfiguration.revision
        == directory.processingConfiguration.revision,
      current.credentialRevision == expectedConfiguration.credentialRevision,
      current.usesStubTMDbResponses == expectedConfiguration.usesStubTMDbResponses,
      current.posterAppearance == expectedConfiguration.posterAppearance,
      current.effectiveMovieMatchingConfiguration(for: configured)
        == expectedConfiguration.effectiveMovieMatchingConfiguration(for: directory)
    else {
      withExtendedLifetime(access) {}
      throw ConfigurationError.configurationChanged
    }

    guard !requiresActiveCollection || !configured.isPaused else {
      withExtendedLifetime(access) {}
      throw ConfigurationError.collectionPaused
    }
    if let childIdentity, requiresActiveCollection, configured.excludesFolder(identity: childIdentity) {
      withExtendedLifetime(access) {}
      throw ConfigurationError.folderExcluded
    }
    guard !current.findOverlappingDirectoryIDs().contains(directory.id) else {
      withExtendedLifetime(access) {}
      throw ConfigurationError.configurationChanged
    }

    return access
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
    guard let access = try store.acquireAccess(for: Self.recordKey) else { throw ConfigurationError.busy }
    var configuration = try read(access)
    try change(&configuration)
    try validate(configuration)
    configuration.version = 3
    try access.write(JSONEncoder().encode(configuration))
    try withExtendedLifetime(access) { try afterCommit() }
  }

  /// Reads the stored configuration under a access and validates its schema.
  ///
  /// - Parameter access: The already-held persistence access used throughout this operation.
  /// - Returns: The validated configuration.
  /// - Throws: Configuration contention or validation errors, persistence failures, or errors propagated by a change.
  private func read(_ access: PersistenceAccess) throws -> DirectoryConfiguration {
    try readIfPresent(access) ?? DirectoryConfiguration()
  }

  /// Decodes only a genuinely persisted record, preserving absence for conditional mutations.
  /// - Parameter access: The exclusive settings access.
  /// - Returns: Validated settings or absence.
  /// - Throws: Persistence or schema failures.
  private func readIfPresent(_ access: PersistenceAccess) throws -> DirectoryConfiguration? {
    guard let data = try access.read() else { return .none }
    let configuration: DirectoryConfiguration
    do { configuration = try JSONDecoder().decode(DirectoryConfiguration.self, from: data) } catch {
      throw ConfigurationError.invalidConfiguration
    }
    try validate(configuration)

    return configuration
  }

  /// Rejects unsupported versions, duplicate roots, and malformed authorization records.
  ///
  /// - Parameter configuration: The complete settings payload to validate or retain.
  /// - Throws: Configuration contention or validation errors, persistence failures, or errors propagated by a change.
  private func validate(_ configuration: DirectoryConfiguration) throws {
    guard (1...3).contains(configuration.version),
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
