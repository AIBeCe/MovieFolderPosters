import Foundation

/// Versioned, per-collection processing state and current membership.
nonisolated public struct CollectionProcessingState: Codable, Sendable, Equatable {
  /// On-disk schema version.
  public var schemaVersion: Int
  /// Monotonically increasing committed revision.
  public var revision: UInt64
  /// Captured root, authorization, and processing settings generation.
  public var context: CollectionProcessingContext
  /// Current operation, if processing is active or most recently terminated.
  public var operation: CollectionProcessingOperation?
  /// Current members and their latest assessments.
  public var folders: [FolderProcessingRecord]
  /// Whether the latest inventory fully classified the immediate children.
  public var isInventoryComplete: Bool
  /// Time the inventory was inspected.
  public var inspectedAt: Date?
  /// Safe inventory issue explanation when the inventory was incomplete.
  public var inventoryIssue: FolderProcessingReason?
  /// Metadata for the latest completed collection-wide run.
  public var lastCompletedRun: CollectionProcessingOperation?
  /// Context in which the latest completed run was recorded, for historical labeling.
  public var lastCompletedRunContext: CollectionProcessingContext?

  /// Preserves the persisted field names independently of Swift property naming.
  private enum CodingKeys: String, CodingKey {
    case schemaVersion, revision, context, operation, folders, isInventoryComplete = "inventoryComplete"
    case inspectedAt, inventoryIssue, lastCompletedRun, lastCompletedRunContext
  }

  /// Creates a snapshot of collection membership, assessments, and operation history.
  ///
  /// - Parameters:
  ///   - schemaVersion: Persisted format version, checked by `validate()` before use.
  ///   - revision: Committed revision used to reject stale writers.
  ///   - context: Root identity, authorization, and settings generation for this snapshot.
  ///   - operation: Active or most recently terminated operation, when recorded.
  ///   - folders: Immediate-child membership and latest individual assessments.
  ///   - isInventoryComplete: Whether inspection classified all immediate children.
  ///   - inspectedAt: Inspection time required for a complete inventory.
  ///   - inventoryIssue: Safe explanation of an incomplete inventory.
  ///   - lastCompletedRun: Latest completed collection-wide operation, when available.
  ///   - lastCompletedRunContext: Generation captured for the historical completed run.
  public init(schemaVersion: Int = 1, revision: UInt64 = .zero, context: CollectionProcessingContext,
              operation: CollectionProcessingOperation? = .none, folders: [FolderProcessingRecord] = [],
              isInventoryComplete: Bool = false, inspectedAt: Date? = .none,
              inventoryIssue: FolderProcessingReason? = .none, lastCompletedRun: CollectionProcessingOperation? = .none,
              lastCompletedRunContext: CollectionProcessingContext? = .none) {
    self.schemaVersion = schemaVersion
    self.revision = revision
    self.context = context
    self.operation = operation
    self.folders = folders
    self.isInventoryComplete = isInventoryComplete
    self.inspectedAt = inspectedAt
    self.inventoryIssue = inventoryIssue
    self.lastCompletedRun = lastCompletedRun
    self.lastCompletedRunContext = lastCompletedRunContext
  }

  /// Whether headline folder counts are supported by a complete inspected inventory.
  public var hasKnownTotal: Bool { isInventoryComplete && inspectedAt != .none }

  /// Validates schema, unique membership, capacity, and Done evidence invariants.
  public func validate() throws {
    guard schemaVersion == 1 else { throw CollectionProcessingError.unsupportedSchema }
    guard folders.count <= 10_000, Set(folders.map(\.name)).count == folders.count else {
      throw CollectionProcessingError.invalidState
    }
    guard folders.allSatisfy({ $0.state != .done || $0.isVerifiedDone }) else {
      throw CollectionProcessingError.invalidState
    }
    guard !isInventoryComplete || inspectedAt != .none else { throw CollectionProcessingError.invalidState }
  }

  /// Counts known assessments while leaving Total unavailable for incomplete inventories.
  public func calculateCounts() -> CollectionProcessingCounts {
    guard hasKnownTotal else {
      return CollectionProcessingCounts(done: .none, notFound: .none, severalMatches: .none, total: .none)
    }
    let assessed = folders.allSatisfy { $0.state != .pending && $0.state != .uncertain }

    return CollectionProcessingCounts(
      done: assessed ? folders.filter { $0.isVerifiedDone }.count : .none,
      notFound: assessed ? folders.filter { $0.state == .notFound }.count : .none,
      severalMatches: assessed ? folders.filter { $0.state == .severalMatches }.count : .none,
      total: folders.count
    )
  }
}
