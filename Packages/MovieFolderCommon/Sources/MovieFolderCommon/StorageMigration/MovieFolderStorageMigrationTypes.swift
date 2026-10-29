import Foundation

/// Existing application record whose schema must be inspected without modifying it.
nonisolated public enum MovieFolderStorageRecordKind: Sendable, Equatable {
  case settings
  case collectionOutcomes(UUID)
  /// Per-root decisions and metadata in the current processing namespace.
  case operationalProcessing(UUID)
}

/// Safe migration failures that retain all earlier successful per-record commits for a later retry.
nonisolated public enum MovieFolderStorageMigrationError: Error, Sendable, Equatable {
  case migrationRequired(record: MovieFolderStorageRecordKind, version: Int)
  case unsupportedVersion(record: MovieFolderStorageRecordKind, version: Int)
  case invalidRecord(record: MovieFolderStorageRecordKind)
  case conflictingValues(record: MovieFolderStorageRecordKind, field: String)
  case busy(record: MovieFolderStorageRecordKind)
  case backupUnavailable(record: MovieFolderStorageRecordKind)
  case backupConflict(record: MovieFolderStorageRecordKind)
  case storageUnavailable(record: MovieFolderStorageRecordKind)
}

/// Read-only evidence used to offer the explicit migration command.
nonisolated public struct MovieFolderStorageMigrationPreflight: Sendable, Equatable {
  /// Whether an existing settings record predates the current schema.
  public let settingsRequiresMigration: Bool
  /// Existing configured outcome records that need conversion.
  public let legacyCollectionOutcomeRecordCount: Int
  /// Configured operational records needing explicit conversion.
  public let legacyOperationalRecordCount: Int
  /// Configured roots without operational decisions.
  public let missingOperationalRecordCount: Int
  /// Existing current settings and outcome records inspected successfully.
  public let currentRecordCount: Int
  /// Configured collections without a persisted outcome record.
  public let missingCollectionOutcomeRecordCount: Int
  /// Creates read-only counts for application composition and controlled test services.
  /// - Parameters:
  ///   - settingsRequiresMigration: Whether a saved settings record uses an older supported schema.
  ///   - legacyCollectionOutcomeRecordCount: Existing configured result records requiring conversion.
  ///   - currentRecordCount: Existing records already using their current schema.
  ///   - missingCollectionOutcomeRecordCount: Configured collections without a result record.
  public init(settingsRequiresMigration: Bool, legacyCollectionOutcomeRecordCount: Int,
              currentRecordCount: Int, missingCollectionOutcomeRecordCount: Int,
              legacyOperationalRecordCount: Int = .zero, missingOperationalRecordCount: Int = .zero) {
    self.legacyOperationalRecordCount = legacyOperationalRecordCount
    self.missingOperationalRecordCount = missingOperationalRecordCount
    self.settingsRequiresMigration = settingsRequiresMigration
    self.legacyCollectionOutcomeRecordCount = legacyCollectionOutcomeRecordCount
    self.currentRecordCount = currentRecordCount
    self.missingCollectionOutcomeRecordCount = missingCollectionOutcomeRecordCount
  }

  /// Whether manual migration has any existing legacy record to convert.
  public var requiresMigration: Bool {
    settingsRequiresMigration || legacyCollectionOutcomeRecordCount > 0 || legacyOperationalRecordCount > 0
  }
}

/// Actual completed migration work; absent outcomes are never manufactured.
nonisolated public struct MovieFolderStorageMigrationReport: Sendable, Equatable {
  /// Records whose backed-up replacement committed in this invocation.
  public let migratedRecordCount: Int
  /// Existing current records intentionally left unchanged.
  public let skippedCurrentRecordCount: Int
  /// Configured collections for which no outcome record existed.
  public let missingCollectionOutcomeRecordCount: Int

  /// Configured roots without an operational record to upgrade.
  public let missingOperationalRecordCount: Int

  /// Creates actual completed counts for application composition and controlled test services.
  /// - Parameters:
  ///   - migratedRecordCount: Backed-up replacements committed in this run.
  ///   - skippedCurrentRecordCount: Existing records left unchanged because their schema is current.
  ///   - missingCollectionOutcomeRecordCount: Configured collections without a result record to upgrade.
  public init(migratedRecordCount: Int, skippedCurrentRecordCount: Int, missingCollectionOutcomeRecordCount: Int,
              missingOperationalRecordCount: Int = .zero) {
    self.missingOperationalRecordCount = missingOperationalRecordCount
    self.migratedRecordCount = migratedRecordCount
    self.skippedCurrentRecordCount = skippedCurrentRecordCount
    self.missingCollectionOutcomeRecordCount = missingCollectionOutcomeRecordCount
  }
}
