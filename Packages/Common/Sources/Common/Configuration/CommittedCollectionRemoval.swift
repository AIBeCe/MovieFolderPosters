import Foundation

/// Immutable evidence minted only after a configured collection removal has committed successfully.
///
/// The receipt cannot be decoded or publicly constructed. Its optional history entry point rechecks current
/// configuration so an identifier reused for a private collection cannot expose an old public name.
nonisolated public struct CommittedCollectionRemoval: Sendable {
  /// Removed collection identity captured under the committed configuration access.
  public let collectionID: UUID
  /// Historical effective display name of the collection at removal.
  public let collectionName: String
  /// Privacy choice in force when the collection was removed.
  public let usedPrivateHistory: Bool

  /// Called only by the shared repository after its configuration write succeeds.
  init(directory: MonitoredDirectory) {
    collectionID = directory.id
    collectionName = directory.effectiveDisplayName
    usedPrivateHistory = directory.usesPrivateHistory
  }
}
