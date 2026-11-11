import Common
import Foundation

/// Removes saved corrections belonging to collections absent from current settings.
nonisolated protocol RemovedCollectionCorrectionsCleaning: Sendable {
  /// Removes obsolete correction records while preserving configured collections.
  func cleanCorrectionsForRemovedCollections() throws
}

/// Keeps current settings stable while removing obsolete correction records.
nonisolated struct RemovedCollectionCorrectionsCleaner: RemovedCollectionCorrectionsCleaning {
  /// Settings defining which collections must retain their corrections.
  let repository: ConfigurationRepository
  /// Opens the correction namespace only when removal is requested.
  let services: MovieFolderServiceFactory

  /// Removes obsolete correction records under the current settings lock.
  /// - Throws: Configuration, storage, or correction-record contention errors.
  func cleanCorrectionsForRemovedCollections() throws {
    let corrections = try services.makeFolderSearchCorrectionStore()
    let (configuration, settingsLock) = try repository.readHoldingAccess()
    defer { withExtendedLifetime(settingsLock) {} }

    try corrections.removeCorrections(keepingCollectionIDs: Set(configuration.directories.map(\.id)))
  }
}
