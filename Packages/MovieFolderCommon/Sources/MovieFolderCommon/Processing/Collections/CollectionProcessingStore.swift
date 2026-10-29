import Foundation
import Persistence

/// Emits a transient hint after a collection processing state is committed.
nonisolated public protocol CollectionProcessingStateChangeNotifying: Sendable {
  /// Announces that readers should reload committed collection processing state.
  func collectionProcessingStateDidChange()
}

/// Coordinates versioned collection processing state with the active settings generation.
nonisolated public struct CollectionProcessingStore: Sendable {
  /// Store containing one bounded record per collection.
  private let store: PersistenceStore
  /// Repository used to validate that the root and settings generation are current.
  private let configuration: ConfigurationRepository
  /// Optional transient hint sender retained by this store.
  private let notifier: (any CollectionProcessingStateChangeNotifying)?

  /// Creates the processing store using shared persistence services.
  ///
  /// - Parameters:
  ///   - store: Dedicated bounded collection processing Persistence namespace.
  ///   - configuration: Current shared settings repository.
  ///   - notifier: Optional hint sender invoked after successful commits.
  public init(
    store: PersistenceStore, configuration: ConfigurationRepository,
    notifier: (any CollectionProcessingStateChangeNotifying)? = .none
  ) {
    self.store = store
    self.configuration = configuration
    self.notifier = notifier
  }

  /// Returns the stable Persistence key for one collection processing state.
  /// - Parameter rootID: Stable configured collection identifier.
  public static func processingStateKey(for rootID: UUID) -> String { "processing-outcome-v1-\(rootID.uuidString)" }

  /// Returns the root-level coordination key shared with processing and orphan checks.
  /// - Parameter root: Configured root URL, canonicalized through symlink resolution.
  public static func coordinationKey(for root: URL) -> String {
    "movie-folder-coordination:\(root.standardizedFileURL.resolvingSymlinksInPath().path)"
  }

  /// Persists operation start and returns the committed initial processing state.
  ///
  /// - Parameters:
  ///   - context: Captured root and settings generation.
  ///   - action: Collection-wide or folder-specific operation action.
  ///   - child: Manual target folder name; omitted for a collection-wide operation.
  ///   - now: Start time, injectable for deterministic callers and tests.
  /// - Returns: The running processing state with a persisted operation identifier.
  /// - Throws: Processing contention, stale configuration, invalid state, or persistence errors.
  /// The caller must hold the shared root-coordination access across the resulting work.
  public func recordProcessingStart(
    context: CollectionProcessingContext, action: CollectionProcessingAction,
    child: String? = .none, now: Date = Date()
  ) throws -> CollectionProcessingState {
    let processingState = try withLocks(context: context, requiresActiveCollection: action != .removal) { access, configuration in
      let stored = try readProcessingState(using: access, expectedRootID: context.rootID)
      var processingState: CollectionProcessingState
      if let stored,
        stored.context.rootIdentity != context.rootIdentity ||
          stored.context.authorizationVersion != context.authorizationVersion {
        processingState = CollectionProcessingState(
          revision: stored.revision,
          context: context,
          lastCompletedRun: stored.lastCompletedRun,
          lastCompletedRunContext: stored.lastCompletedRunContext
        )
      } else if let stored, !stored.context.hasSameProcessingInputs(as: context) {
        processingState = stored
        processingState.context = context
        processingState.folders = stored.folders.map { FolderProcessingRecord(name: $0.name) }
        processingState.isInventoryComplete = false
        processingState.inspectedAt = .none
        processingState.inventoryIssue = .inventoryPending
      } else {
        processingState = stored ?? CollectionProcessingState(context: context)
        if let stored, stored.context.processingConfigurationRevision != context.processingConfigurationRevision {
          Self.reconcileInclusion(in: &processingState, configuration: configuration, now: now)
        }
      }
      try Self.validateRootGeneration(processingState, matches: context)

      if action == .automatic {
        processingState.folders = []
        processingState.isInventoryComplete = false
        processingState.inspectedAt = .none
        processingState.inventoryIssue = .inventoryPending
      } else if let child {
        if let index = processingState.folders.firstIndex(where: { $0.name == child }) {
          processingState.folders[index].state = .pending
          processingState.folders[index].reason = .none
          processingState.folders[index].assessedAt = .none
        } else {
          processingState.folders.append(FolderProcessingRecord(name: child))
          processingState.isInventoryComplete = false
          processingState.inspectedAt = .none
        }
      }

      processingState.context = context
      processingState.currentRun = CollectionProcessingRun(action: action, startedAt: now)
      guard processingState.revision < UInt64.max else { throw CollectionProcessingError.revisionExhausted }
      processingState.revision += 1
      try processingState.validate()
      try Self.write(processingState, to: access)

      return processingState
    }
    notifier?.collectionProcessingStateDidChange()

    return processingState
  }

  /// Commits a changed processing state only if its operation and revision remain current.
  ///
  /// - Parameters:
  ///   - processingState: Proposed complete replacement processing state.
  ///   - expectedRevision: Revision previously returned to the writer.
  /// - Returns: The processing state with the next committed revision.
  /// - Throws: Stale operation/revision, configuration change, validation, or persistence errors.
  /// The caller must hold the shared root-coordination access throughout the commit.
  public func commit(
    _ processingState: CollectionProcessingState,
    expectedRevision: UInt64
  ) throws -> CollectionProcessingState {
    let committed = try withLocks(
      context: processingState.context, requiresActiveCollection: processingState.currentRun?.action != .removal
    ) { access, _ in
      guard let current = try readProcessingState(using: access, expectedRootID: processingState.context.rootID) else {
        throw CollectionProcessingError.staleRevision
      }
      guard current.revision == expectedRevision else { throw CollectionProcessingError.staleRevision }
      guard current.currentRun?.id == processingState.currentRun?.id else {
        throw CollectionProcessingError.staleRun
      }
      guard current.context == processingState.context else { throw CollectionProcessingError.configurationChanged }
      try processingState.validate()

      var committed = processingState
      guard current.revision < UInt64.max else { throw CollectionProcessingError.revisionExhausted }
      committed.revision = current.revision + 1
      if let run = committed.currentRun,
        run.state == .completed, run.action == .automatic {
        committed.lastCompletedRun = run
        committed.lastCompletedRunContext = committed.context
      }
      try committed.validate()
      try Self.write(committed, to: access)

      return committed
    }
    notifier?.collectionProcessingStateDidChange()

    return committed
  }

  /// Reads a collection processing state without creating a missing record.
  ///
  /// - Parameter rootID: Stable configured root identifier.
  /// - Returns: A validated processing state, or `nil` when no result exists.
  /// - Throws: Processing contention, corrupt/unsupported data, or persistence errors.
  public func read(rootID: UUID) throws -> CollectionProcessingState? {
    guard let access = try store.acquireAccess(for: Self.processingStateKey(for: rootID)) else {
      throw CollectionProcessingError.busy
    }

    return try readProcessingState(using: access, expectedRootID: rootID)
  }

  /// Removes only saved states whose roots are absent from the current validated settings.
  ///
  /// - Returns: Persistence digests that were busy and can be retried on a later normal invocation.
  /// - Throws: Settings validation, contention, or persistence failures. Invalid settings prevent cleanup.
  public func pruneToConfiguredRoots() throws -> Set<String> {
    let (saved, settingsAccess) = try configuration.readHoldingAccess()
    let keys = Set(saved.directories.map { Self.processingStateKey(for: $0.id) })

    return try withExtendedLifetime(settingsAccess) { try store.pruneRecords(keepingKeys: keys) }
  }

  /// Acquires settings and short processing state leases; callers retain root coordination across work.
  private func withLocks<T>(
    context: CollectionProcessingContext, requiresActiveCollection: Bool,
    _ body: (PersistenceAccess, CollectionProcessingConfiguration) throws -> T
  ) throws -> T {
    let (currentConfiguration, settingsAccess) = try configuration.readHoldingAccess()
    try Self.validate(context, against: currentConfiguration, requiresActiveCollection: requiresActiveCollection)

    guard let root = currentConfiguration.directories.first(where: { $0.id == context.rootID }) else {
      throw CollectionProcessingError.rootRemoved
    }

    guard let processingStateAccess = try store.acquireAccess(for: Self.processingStateKey(for: context.rootID)) else {
      withExtendedLifetime(settingsAccess) {}
      throw CollectionProcessingError.busy
    }

    return try withExtendedLifetime((settingsAccess, processingStateAccess)) {
      try body(processingStateAccess, root.processingConfiguration)
    }
  }

  /// Reconciles identity-based inclusion while retaining unrelated assessments and icon ownership evidence.
  /// Suppression has precedence: Include never clears the explicit configuration preventing poster recreation.
  private static func reconcileInclusion(
    in state: inout CollectionProcessingState, configuration: CollectionProcessingConfiguration, now: Date
  ) {
    for index in state.folders.indices {
      guard state.folders[index].state != .suppressed else { continue }

      let isExcluded = state.folders[index].identity.map { configuration.excludesFolder(identity: $0) } ?? false
      if isExcluded {
        state.folders[index].state = .excluded
        state.folders[index].reason = .explicitExclusion
        state.folders[index].assessedAt = now
        state.folders[index].retryAt = .none
      } else if state.folders[index].state == .excluded {
        state.folders[index].state = .pending
        state.folders[index].reason = .inventoryPending
        state.folders[index].assessedAt = .none
        state.folders[index].retryAt = .none
      }
    }
  }

  /// Checks the captured root and settings generations against current saved configuration.
  private static func validate(
    _ context: CollectionProcessingContext, against saved: DirectoryConfiguration, requiresActiveCollection: Bool
  ) throws {
    guard let root = saved.directories.first(where: { $0.id == context.rootID }) else {
      throw CollectionProcessingError.rootRemoved
    }
    guard root.identity == context.rootIdentity,
      root.authorizationVersion == context.authorizationVersion,
      saved.credentialRevision == context.credentialRevision,
      saved.usesStubTMDbResponses == context.usesStubTMDbResponses,
      saved.posterAppearance == context.appearance,
      saved.effectiveMovieMatchingConfiguration(for: root) == context.movieMatchingConfiguration,
      !requiresActiveCollection || !root.processingConfiguration.isPaused,
      root.processingConfiguration.revision == context.processingConfigurationRevision,
      !saved.findOverlappingDirectoryIDs().contains(context.rootID)
    else { throw CollectionProcessingError.configurationChanged }
  }

  /// Ensures the existing record belongs to the same root generation before changing it.
  private static func validateRootGeneration(
    _ processingState: CollectionProcessingState,
    matches context: CollectionProcessingContext
  ) throws {
    try processingState.validate()
    guard processingState.context.rootID == context.rootID,
      processingState.context.rootIdentity == context.rootIdentity,
      processingState.context.authorizationVersion == context.authorizationVersion
    else { throw CollectionProcessingError.configurationChanged }
  }

  /// Decodes a bounded record and rejects mismatched or unsupported states.
  /// - Parameters:
  ///   - persistenceAccess: Held access for the outcome record.
  ///   - expectedRootID: Root identity that the decoded outcome must match.
  /// - Returns: Decoded state, or `nil` when the record has no payload.
  /// - Throws: A migration error when reading or validating the saved state fails.
  private func readProcessingState(
    using persistenceAccess: PersistenceAccess, expectedRootID: UUID
  ) throws -> CollectionProcessingState? {
    let payload: Data?
    do { payload = try persistenceAccess.read() } catch {
      throw MovieFolderStorageMigrationError.storageUnavailable(record: .collectionOutcomes(expectedRootID))
    }

    return try decode(payload, expectedRootID: expectedRootID)
  }

  /// Distinguishes legacy, future, and malformed saved payloads without rewriting them.
  private func decode(_ data: Data?, expectedRootID: UUID) throws -> CollectionProcessingState? {
    guard let data else { return .none }
    let processingState: CollectionProcessingState
    do {
      let version = try JSONDecoder().decode(CollectionOutcomeSchemaVersion.self, from: data).schemaVersion

      guard version == 3 else {
        if (1...2).contains(version) {
          throw MovieFolderStorageMigrationError.migrationRequired(
            record: .collectionOutcomes(expectedRootID), version: version)
        }
        throw MovieFolderStorageMigrationError.unsupportedVersion(
          record: .collectionOutcomes(expectedRootID), version: version)
      }

      processingState = try JSONDecoder().decode(CollectionProcessingState.self, from: data)

      guard processingState.context.rootID == expectedRootID else {
        throw MovieFolderStorageMigrationError.invalidRecord(record: .collectionOutcomes(expectedRootID))
      }

      try processingState.validate()
    } catch let error as MovieFolderStorageMigrationError {
      throw error
    } catch {
      throw MovieFolderStorageMigrationError.invalidRecord(record: .collectionOutcomes(expectedRootID))
    }

    return processingState
  }

  /// Encodes deterministically and writes the complete processing state within the access.
  private static func write(_ processingState: CollectionProcessingState, to access: PersistenceAccess) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try access.write(encoder.encode(processingState))
  }
}

/// Reads the outer outcome version before inspecting potentially renamed nested context fields.
private struct CollectionOutcomeSchemaVersion: Decodable {
  /// Saved record format, independent of processing revision.
  let schemaVersion: Int
}
