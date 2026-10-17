import Foundation
import Persistence

/// Emits a transient hint after a collection processing state is committed.
nonisolated public protocol CollectionProcessingChangeNotifying: Sendable {
  /// Announces that readers should reload committed collection processing state.
  func collectionProcessingDidChange()
}

/// Coordinates versioned collection processing state with the active settings generation.
nonisolated public struct CollectionProcessingStore: Sendable {
  /// Store containing one bounded record per collection.
  private let store: PersistenceStore
  /// Repository used to validate that the root and settings generation are current.
  private let configuration: ConfigurationRepository
  /// Optional transient hint sender retained by this store.
  private let notifier: (any CollectionProcessingChangeNotifying)?

  /// Creates the processing store inside the application target using shared persistence services.
  ///
  /// - Parameters:
  ///   - store: Dedicated bounded collection processing Persistence namespace.
  ///   - configuration: Current shared settings repository.
  ///   - notifier: Optional hint sender invoked after successful commits.
  init(store: PersistenceStore, configuration: ConfigurationRepository,
       notifier: (any CollectionProcessingChangeNotifying)? = nil) {
    self.store = store
    self.configuration = configuration
    self.notifier = notifier
  }

  /// Returns the stable Persistence key for one collection processing state.
  /// - Parameter rootID: Stable configured collection identifier.
  public static func rootKey(_ rootID: UUID) -> String { "processing-outcome-v1-\(rootID.uuidString)" }

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
  /// The caller must hold the shared root-coordination lease across the resulting work.
  public func recordProcessingStart(context: CollectionProcessingContext, action: CollectionProcessingAction,
                    child: String? = nil, now: Date = Date()) throws -> CollectionProcessingState {
    let processingState = try withLocks(context: context) { lease in
      let stored = try decode(lease.read(), expectedRootID: context.rootID)
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
      } else if let stored, stored.context != context {
        processingState = stored
        processingState.context = context
        processingState.folders = stored.folders.map { FolderProcessingRecord(name: $0.name) }
        processingState.isInventoryComplete = false
        processingState.inspectedAt = nil
        processingState.inventoryIssue = .inventoryPending
      } else {
        processingState = stored ?? CollectionProcessingState(context: context)
      }
      try Self.validateRootGeneration(processingState, matches: context)

      if action == .automatic {
        processingState.folders = []
        processingState.isInventoryComplete = false
        processingState.inspectedAt = nil
        processingState.inventoryIssue = .inventoryPending
      } else if let child {
        if let index = processingState.folders.firstIndex(where: { $0.name == child }) {
          processingState.folders[index].state = .pending
          processingState.folders[index].reason = nil
          processingState.folders[index].assessedAt = nil
        } else {
          processingState.folders.append(FolderProcessingRecord(name: child))
          processingState.isInventoryComplete = false
          processingState.inspectedAt = nil
        }
      }

      processingState.context = context
      processingState.operation = CollectionProcessingOperation(action: action, startedAt: now)
      guard processingState.revision < UInt64.max else { throw CollectionProcessingError.revisionExhausted }
      processingState.revision += 1
      try processingState.validate()
      try Self.write(processingState, to: lease)

      return processingState
    }
    notifier?.collectionProcessingDidChange()
    return processingState
  }

  /// Commits a changed processing state only if its operation and revision remain current.
  ///
  /// - Parameters:
  ///   - processingState: Proposed complete replacement processing state.
  ///   - expectedRevision: Revision previously returned to the writer.
  /// - Returns: The processing state with the next committed revision.
  /// - Throws: Stale operation/revision, configuration change, validation, or persistence errors.
  /// The caller must hold the shared root-coordination lease throughout the commit.
  public func commit(
    _ processingState: CollectionProcessingState,
    expectedRevision: UInt64
  ) throws -> CollectionProcessingState {
    let committed = try withLocks(context: processingState.context) { lease in
      guard let current = try decode(lease.read(), expectedRootID: processingState.context.rootID) else {
        throw CollectionProcessingError.staleRevision
      }
      guard current.revision == expectedRevision else { throw CollectionProcessingError.staleRevision }
      guard current.operation?.id == processingState.operation?.id else {
        throw CollectionProcessingError.staleOperation
      }
      guard current.context == processingState.context else { throw CollectionProcessingError.configurationChanged }
      try processingState.validate()

      var committed = processingState
      guard current.revision < UInt64.max else { throw CollectionProcessingError.revisionExhausted }
      committed.revision = current.revision + 1
      if let operation = committed.operation,
        operation.state == .completed, operation.action == .automatic
      {
        committed.lastCompletedRun = operation
        committed.lastCompletedRunContext = committed.context
      }
      try committed.validate()
      try Self.write(committed, to: lease)

      return committed
    }
    notifier?.collectionProcessingDidChange()
    return committed
  }

  /// Reads a collection processing state without creating a missing record.
  ///
  /// - Parameter rootID: Stable configured root identifier.
  /// - Returns: A validated processing state, or `nil` when no result exists.
  /// - Throws: Processing contention, corrupt/unsupported data, or persistence errors.
  public func read(rootID: UUID) throws -> CollectionProcessingState? {
    guard let lease = try store.acquireLease(for: Self.rootKey(rootID)) else {
      throw CollectionProcessingError.busy
    }
    return try decode(lease.read(), expectedRootID: rootID)
  }

  /// Removes only saved states whose roots are absent from the current validated settings.
  ///
  /// - Returns: Persistence digests that were busy and can be retried on a later normal invocation.
  /// - Throws: Settings validation, contention, or persistence failures. Invalid settings prevent cleanup.
  public func pruneToConfiguredRoots() throws -> Set<String> {
    let (saved, settingsLease) = try configuration.readHoldingLease()
    let keys = Set(saved.directories.map { Self.rootKey($0.id) })
    return try withExtendedLifetime(settingsLease) {
      try store.pruneRecords(keepingKeys: keys)
    }
  }

  /// Acquires settings and short processing state leases; callers retain root coordination across work.
  private func withLocks<T>(context: CollectionProcessingContext, _ body: (PersistenceLease) throws -> T) throws -> T {
    let (currentConfiguration, settingsLease) = try configuration.readHoldingLease()
    try Self.validate(context, against: currentConfiguration)
    guard let processingStateLease = try store.acquireLease(for: Self.rootKey(context.rootID)) else {
      withExtendedLifetime(settingsLease) {}
      throw CollectionProcessingError.busy
    }
    return try withExtendedLifetime((settingsLease, processingStateLease)) {
      try body(processingStateLease)
    }
  }

  /// Checks the captured root and settings generations against current saved configuration.
  private static func validate(_ context: CollectionProcessingContext, against saved: DirectoryConfiguration) throws {
    guard let root = saved.directories.first(where: { $0.id == context.rootID }) else {
      throw CollectionProcessingError.rootRemoved
    }
    guard root.identity == context.rootIdentity,
      root.authorizationVersion == context.authorizationVersion,
      saved.credentialRevision == context.credentialRevision,
      saved.developmentFixtures == context.developmentFixtures,
      saved.posterAppearance == context.appearance,
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
  private func decode(_ data: Data?, expectedRootID: UUID) throws -> CollectionProcessingState? {
    guard let data else { return nil }
    let processingState: CollectionProcessingState
    do { processingState = try JSONDecoder().decode(CollectionProcessingState.self, from: data) }
    catch { throw CollectionProcessingError.unavailable }
    guard processingState.context.rootID == expectedRootID else { throw CollectionProcessingError.invalidState }
    try processingState.validate()
    return processingState
  }

  /// Encodes deterministically and writes the complete processing state within the lease.
  private static func write(_ processingState: CollectionProcessingState, to lease: PersistenceLease) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try lease.write(encoder.encode(processingState))
  }
}
