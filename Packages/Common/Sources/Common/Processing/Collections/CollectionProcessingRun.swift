import Foundation

/// Type of collection processing run.
nonisolated public enum CollectionProcessingAction: String, Codable, Sendable {
  case automatic, manual, refresh, selection, removal
}
/// Lifecycle state of a collection processing run.
nonisolated public enum CollectionProcessingRunState: String, Codable, Sendable {
  case running, completed, partial, interrupted, failed
}
/// Persisted metadata for a collection processing run.
nonisolated public struct CollectionProcessingRun: Codable, Sendable, Equatable {
  /// Stable identifier used to reject writes from an earlier run.
  public let id: UUID
  /// Run scope, including collection-wide and manual actions.
  public let action: CollectionProcessingAction
  /// Start time persisted before processing change begins.
  public let startedAt: Date
  /// End time, absent while the run remains active.
  public var endedAt: Date?
  /// Current lifecycle result.
  public var runState: CollectionProcessingRunState
  /// Preserves the persisted field names independently of Swift property naming.
  private enum CodingKeys: String, CodingKey { case id, action = "kind", startedAt, endedAt
    case runState = "state" }

  /// Creates run metadata with a fresh identifier by default.
  ///
  /// - Parameters:
  ///   - id: Stable run identifier.
  ///   - action: Scope of the run.
  ///   - startedAt: Time the run start was persisted.
  ///   - endedAt: Time the run ended, if known.
  ///   - runState: Current lifecycle result.
  public init(id: UUID = UUID(), action: CollectionProcessingAction, startedAt: Date,
              endedAt: Date? = .none, runState: CollectionProcessingRunState = .running) {
    self.id = id
    self.action = action
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.runState = runState
  }
}
