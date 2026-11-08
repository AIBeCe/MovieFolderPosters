import Foundation

/// A safely persisted failure stage or category from the most recent failure.
nonisolated public struct AutomaticFolderProcessingFailure: Codable, Sendable, Equatable {
  /// Stable error category safe for presentation.
  public let reason: FolderProcessingFailureReason
  /// Processing stage at which the attempt ended.
  public let stage: FolderProcessingStage
  /// Time the attempt ended.
  public let occurredAt: Date
  /// Preserves the persisted field names independently of Swift property naming.
  private enum CodingKeys: String, CodingKey { case reason = "code", stage, occurredAt }

  /// Creates allowlisted evidence for the most recent attempt.
  ///
  /// - Parameters:
  ///   - reason: Stable failure category without private provider or filesystem text.
  ///   - stage: Processing stage where the attempt ended.
  ///   - occurredAt: Time the attempt ended.
  public init(reason: FolderProcessingFailureReason, stage: FolderProcessingStage, occurredAt: Date) {
    self.reason = reason
    self.stage = stage
    self.occurredAt = occurredAt
  }
}
/// Allowlisted failure categories that never contain raw provider or filesystem errors.
nonisolated public enum FolderProcessingFailureReason: String, Codable, Sendable {
  case cancelled, unavailable, invalidResponse, authentication, rateLimited, timeout
  case filesystem, ownershipChanged, storage, capacity, unknown
  case connectivity, serverFailure, recoveryMode
  case duplicateCollection, overlappingCollection, configurationChanged, authorizationDenied
  case invalidSelection, invalidQuery, credentialStorage, invalidConfiguration, busy, collectionPaused, folderExcluded
  case movieIdentityUnresolved, foreignIcon, missingPoster
  case storageMigrationRequired, unsupportedStorageVersion, invalidSavedData, migrationBackupFailed
}
/// Processing stage associated with the latest safe failure category.
nonisolated public enum FolderProcessingStage: String, Codable, Sendable {
  case inventory, parse, search, artwork, validateIdentity, assignPoster, persist, unknown
}
