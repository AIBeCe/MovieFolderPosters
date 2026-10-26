import Foundation

/// Versioned, per-collection processing state and current membership.
nonisolated public struct CollectionProcessingState: Codable, Sendable, Equatable {
  /// On-disk schema version.
  public var schemaVersion: Int
  /// Monotonically increasing committed revision.
  public var revision: UInt64
  /// Captured root, authorization, and processing settings generation.
  public var context: CollectionProcessingContext
  /// Current or most recently terminated collection run.
  public var currentRun: CollectionProcessingRun?
  /// Current members and their latest assessments.
  public var folders: [FolderProcessingRecord]
  /// Whether the latest inventory fully classified the immediate children.
  public var isInventoryComplete: Bool
  /// Time the inventory was inspected.
  public var inspectedAt: Date?
  /// Safe inventory issue explanation when the inventory was incomplete.
  public var inventoryIssue: FolderProcessingReason?
  /// Metadata for the latest completed collection-wide run.
  public var lastCompletedRun: CollectionProcessingRun?
  /// Context in which the latest completed run was recorded, for historical labeling.
  public var lastCompletedRunContext: CollectionProcessingContext?

  /// Preserves the persisted field names independently of Swift property naming.
  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schemaVersion"
    case revision = "revision"
    case context = "context"
    case currentRun = "operation"
    case folders = "folders"
    case isInventoryComplete = "inventoryComplete"
    case inspectedAt = "inspectedAt"
    case inventoryIssue = "inventoryIssue"
    case lastCompletedRun = "lastCompletedRun"
    case lastCompletedRunContext = "lastCompletedRunContext"
  }

  /// Creates saved collection membership, assessments, and run history.
  ///
  /// - Parameters:
  ///   - schemaVersion: Persisted format version, checked by `validate()` before use.
  ///   - revision: Committed revision used to reject stale writers.
  ///   - context: Root identity, authorization, and settings generation for this saved state.
  ///   - currentRun: Active or most recently terminated run, when recorded.
  ///   - folders: Immediate-child membership and latest individual assessments.
  ///   - isInventoryComplete: Whether inspection classified all immediate children.
  ///   - inspectedAt: Inspection time required for a complete inventory.
  ///   - inventoryIssue: Safe explanation of an incomplete inventory.
  ///   - lastCompletedRun: Latest completed collection-wide run, when available.
  ///   - lastCompletedRunContext: Generation captured for the historical completed run.
  public init(schemaVersion: Int = 2, revision: UInt64 = .zero, context: CollectionProcessingContext,
              currentRun: CollectionProcessingRun? = .none, folders: [FolderProcessingRecord] = [],
              isInventoryComplete: Bool = false, inspectedAt: Date? = .none,
              inventoryIssue: FolderProcessingReason? = .none, lastCompletedRun: CollectionProcessingRun? = .none,
              lastCompletedRunContext: CollectionProcessingContext? = .none) {
    self.schemaVersion = schemaVersion
    self.revision = revision
    self.context = context
    self.currentRun = currentRun
    self.folders = folders
    self.isInventoryComplete = isInventoryComplete
    self.inspectedAt = inspectedAt
    self.inventoryIssue = inventoryIssue
    self.lastCompletedRun = lastCompletedRun
    self.lastCompletedRunContext = lastCompletedRunContext
  }

  /// Decodes current outcomes without mutating or silently converting saved legacy data.
  /// - Parameter decoder: Current schema-two collection outcome fields.
  /// - Throws: Decoding errors for malformed fields, or a migration error for an unsupported schema.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
    let contextFields = try values.nestedContainer(keyedBy: ContextIdentityKeys.self, forKey: .context)
    let rootID = try contextFields.decode(UUID.self, forKey: .rootID)

    guard schemaVersion == 2 else {
      if schemaVersion == 1 {
        throw MovieFolderStorageMigrationError.migrationRequired(record: .collectionOutcomes(rootID), version: 1)
      }
      throw MovieFolderStorageMigrationError.unsupportedVersion(
        record: .collectionOutcomes(rootID), version: schemaVersion)
    }

    revision = try values.decode(UInt64.self, forKey: .revision)
    context = try values.decode(CollectionProcessingContext.self, forKey: .context)
    currentRun = try values.decodeIfPresent(CollectionProcessingRun.self, forKey: .currentRun)
    folders = try values.decode([FolderProcessingRecord].self, forKey: .folders)
    isInventoryComplete = try values.decode(Bool.self, forKey: .isInventoryComplete)
    inspectedAt = try values.decodeIfPresent(Date.self, forKey: .inspectedAt)
    inventoryIssue = try values.decodeIfPresent(FolderProcessingReason.self, forKey: .inventoryIssue)
    lastCompletedRun = try values.decodeIfPresent(CollectionProcessingRun.self, forKey: .lastCompletedRun)
    lastCompletedRunContext = try values.decodeIfPresent(
      CollectionProcessingContext.self, forKey: .lastCompletedRunContext)
  }

  /// Encodes only current outcomes; legacy payload changes belong to the explicit migrator.
  /// - Parameter encoder: Destination for current collection outcome fields.
  /// - Throws: A migration error for a noncurrent schema, or an encoding error from the destination encoder.
  public func encode(to encoder: any Encoder) throws {
    guard schemaVersion == 2 else {
      throw MovieFolderStorageMigrationError.invalidRecord(record: .collectionOutcomes(context.rootID))
    }

    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(schemaVersion, forKey: .schemaVersion)
    try values.encode(revision, forKey: .revision)
    try values.encode(context, forKey: .context)
    try values.encodeIfPresent(currentRun, forKey: .currentRun)
    try values.encode(folders, forKey: .folders)
    try values.encode(isInventoryComplete, forKey: .isInventoryComplete)
    try values.encodeIfPresent(inspectedAt, forKey: .inspectedAt)
    try values.encodeIfPresent(inventoryIssue, forKey: .inventoryIssue)
    try values.encodeIfPresent(lastCompletedRun, forKey: .lastCompletedRun)
    try values.encodeIfPresent(lastCompletedRunContext, forKey: .lastCompletedRunContext)
  }

  /// Root identity is sufficient to describe an old schema before decoding renamed nested fields.
  private enum ContextIdentityKeys: String, CodingKey { case rootID }

  /// Whether headline folder counts are supported by a complete inspected inventory.
  public var hasKnownTotal: Bool { isInventoryComplete && inspectedAt != .none }

  /// Validates schema, unique membership, capacity, and Done evidence invariants.
  public func validate() throws {
    guard schemaVersion == 2 else {
      if schemaVersion == 1 {
        throw MovieFolderStorageMigrationError.migrationRequired(
          record: .collectionOutcomes(context.rootID), version: 1)
      }
      throw MovieFolderStorageMigrationError.unsupportedVersion(
        record: .collectionOutcomes(context.rootID), version: schemaVersion)
    }
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
