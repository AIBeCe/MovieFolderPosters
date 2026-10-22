import Foundation
import Persistence

/// Persists validated shared settings under a cross-process lease.
nonisolated public struct ConfigurationRepository: Sendable {
  /// The persistence record shared by all readers of this versioned payload.
  public static let recordKey = "directory-configuration-v1"
  /// The persistence store supplying cross-process leases and atomic record writes.
  let store: PersistenceStore

  /// Creates a settings repository backed by the caller's dedicated persistence namespace.
  /// - Parameter store: The store holding the versioned settings record and cross-process lease.
  public init(store: PersistenceStore) { self.store = store }

  /// Reads the stored configuration under a lease and validates its schema.
  /// - Returns: The validated configuration.
  /// - Throws: Configuration contention or validation errors, persistence failures, or errors propagated by a mutation.
  public func read() throws -> DirectoryConfiguration {
    let (configuration, lease) = try readHoldingLease()

    return withExtendedLifetime(lease) { configuration }
  }

  /// Returns validated settings together with the lease that keeps them stable.
  /// - Returns: The validated configuration and the lease keeping that configuration stable.
  /// - Throws: Configuration contention or validation errors, persistence failures, or errors propagated by a mutation.
  public func readHoldingLease() throws -> (DirectoryConfiguration, PersistenceLease) {
    guard let lease = try store.acquireLease(for: Self.recordKey) else { throw ConfigurationError.busy }

    return (try read(lease), lease)
  }

  /// Reads persisted settings without manufacturing a generation for a missing record.
  /// - Returns: Optional validated settings and their exclusive lease.
  /// - Throws: Busy, invalid settings, or persistence failures.
  public func readIfPresentHoldingLease() throws -> (DirectoryConfiguration?, PersistenceLease) {
    guard let lease = try store.acquireLease(for: Self.recordKey) else { throw ConfigurationError.busy }

    return (try readIfPresent(lease), lease)
  }

  /// Commits a credential generation before mutating Keychain under the same lease.
  /// - Parameters:
  ///   - expectedRevision: Persisted generation, or absence captured on first run.
  ///   - afterCommit: Credential mutation; failure never rolls the settings generation back.
  /// - Throws: Cancellation, stale configuration, persistence, or credential mutation failures.
  public func updateCredential(expectedRevision: UUID?, afterCommit: () throws -> Void = {}) throws {
    let (saved, lease) = try readIfPresentHoldingLease()
    try Task.checkCancellation()
    guard saved?.credentialRevision == expectedRevision else { throw ConfigurationError.configurationChanged }
    var configuration = saved ?? DirectoryConfiguration()
    configuration.version = 2
    configuration.credentialRevision = UUID()
    try validate(configuration)
    try lease.write(JSONEncoder().encode(configuration))
    try withExtendedLifetime(lease) { try afterCommit() }
  }

  /// Checks that the captured root and settings generation still authorize mutation.
  ///
  /// - Parameters:
  ///   - directory: The authorized collection root.
  ///   - expectedConfiguration: The settings generation captured before provider work began.
  /// - Returns: The settings lease to retain until the validated mutation finishes.
  /// - Throws: Configuration contention or validation errors, persistence failures, or errors propagated by a mutation.
  public func mutationLease(
    for directory: MonitoredDirectory,
    expectedConfiguration: DirectoryConfiguration
  ) throws -> PersistenceLease {
    let (current, lease) = try readHoldingLease()
    guard let configured = current.directories.first(where: { $0.id == directory.id }),
      configured.path == directory.path,
      configured.identity == directory.identity,
      configured.authorizationVersion == directory.authorizationVersion,
      !current.findOverlappingDirectoryIDs().contains(directory.id),
      current.credentialRevision == expectedConfiguration.credentialRevision,
      current.usesStubTMDbResponses == expectedConfiguration.usesStubTMDbResponses,
      current.posterAppearance == expectedConfiguration.posterAppearance
    else {
      withExtendedLifetime(lease) {}
      throw ConfigurationError.configurationChanged
    }

    return lease
  }

  /// Retries short-lived configuration contention within a fixed attempt budget.
  ///
  /// - Parameter pause: The cancellable delay between bounded attempts at reading busy settings.
  /// - Returns: The validated configuration.
  /// - Throws: Configuration contention or validation errors, persistence failures, or errors propagated by a mutation.
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

  /// Validates and commits a settings mutation before running its post-commit action under the same lease.
  ///
  /// - Parameters:
  ///   - mutation: The in-place configuration change performed before validation and commit.
  ///   - afterCommit: The action invoked only after persistence succeeds while the lease remains held.
  /// - Throws: Configuration contention or validation errors, persistence failures, or errors propagated by a mutation.
  public func update(
    _ mutation: (inout DirectoryConfiguration) throws -> Void,
    afterCommit: () throws -> Void = {}
  ) throws {
    guard let lease = try store.acquireLease(for: Self.recordKey) else { throw ConfigurationError.busy }
    var configuration = try read(lease)
    try mutation(&configuration)
    try validate(configuration)
    configuration.version = 2
    try lease.write(JSONEncoder().encode(configuration))
    try withExtendedLifetime(lease) { try afterCommit() }
  }

  /// Reads the stored configuration under a lease and validates its schema.
  ///
  /// - Parameter lease: The already-held persistence lease used throughout this operation.
  /// - Returns: The validated configuration.
  /// - Throws: Configuration contention or validation errors, persistence failures, or errors propagated by a mutation.
  private func read(_ lease: PersistenceLease) throws -> DirectoryConfiguration {
    try readIfPresent(lease) ?? DirectoryConfiguration()
  }

  /// Decodes only a genuinely persisted record, preserving absence for conditional mutations.
  /// - Parameter lease: The exclusive settings lease.
  /// - Returns: Validated settings or absence.
  /// - Throws: Persistence or schema failures.
  private func readIfPresent(_ lease: PersistenceLease) throws -> DirectoryConfiguration? {
    guard let data = try lease.read() else { return .none }
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
  /// - Throws: Configuration contention or validation errors, persistence failures, or errors propagated by a mutation.
  private func validate(_ configuration: DirectoryConfiguration) throws {
    guard (1...2).contains(configuration.version),
      Set(configuration.directories.map(\.id)).count == configuration.directories.count,
      Set(configuration.directories.map(\.path)).count == configuration.directories.count,
      configuration.directories.allSatisfy({ $0.path.hasPrefix("/") && !$0.transferBookmark.isEmpty })
    else {
      throw ConfigurationError.invalidConfiguration
    }
  }
}
