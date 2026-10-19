import Foundation

/// Type of the currently persisted operation.
nonisolated public enum CollectionProcessingAction: String, Codable, Sendable {
  case automatic, manual, refresh, selection, removal
}
/// Lifecycle state of the current operation.
nonisolated public enum CollectionProcessingOperationState: String, Codable, Sendable {
  case running, completed, partial, interrupted, failed
}
/// Persisted metadata for the current operation.
nonisolated public struct CollectionProcessingOperation: Codable, Sendable, Equatable {
  /// Stable identifier used to reject writes from an earlier operation.
  public let id: UUID
  /// Operation scope, including collection-wide and manual actions.
  public let action: CollectionProcessingAction
  /// Start time persisted before processing mutation begins.
  public let startedAt: Date
  /// End time, absent while the operation remains active.
  public var endedAt: Date?
  /// Current lifecycle result.
  public var state: CollectionProcessingOperationState
  /// Preserves the persisted field names independently of Swift property naming.
  private enum CodingKeys: String, CodingKey { case id, action = "kind", startedAt, endedAt, state }

  /// Creates operation metadata with a fresh identifier by default.
  ///
  /// - Parameters:
  ///   - id: Stable operation identifier.
  ///   - action: Scope of the operation.
  ///   - startedAt: Time operation start was persisted.
  ///   - endedAt: Time the operation ended, if known.
  ///   - state: Current lifecycle result.
  public init(id: UUID = UUID(), action: CollectionProcessingAction, startedAt: Date,
              endedAt: Date? = .none, state: CollectionProcessingOperationState = .running) {
    self.id = id
    self.action = action
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.state = state
  }
}
