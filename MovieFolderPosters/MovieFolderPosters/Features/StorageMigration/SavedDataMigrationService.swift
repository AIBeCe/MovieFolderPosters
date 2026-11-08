import Foundation
import Common

/// Runs an explicitly requested saved-data upgrade independently of configuration startup.
nonisolated protocol SavedDataMigrationServicing: Sendable {
  /// Upgrades supported existing records after preserving their original payloads.
  /// - Returns: Actual committed, unchanged and absent-record counts.
  /// - Throws: A safe migration, storage or cancellation failure; completed records remain upgraded.
  func migrateSavedData() async throws -> MovieFolderStorageMigrationReport
}

/// Uses the shared migration service on a utility task without opening access tokens or movie folders.
nonisolated struct SavedApplicationDataMigrationService: SavedDataMigrationServicing {
  let makeMigrator: @Sendable () throws -> MovieFolderStorageMigrator

  init(makeMigrator: @escaping @Sendable () throws -> MovieFolderStorageMigrator =
    MovieFolderServiceFactory(locations: MovieFolderSystemStorageLocations()).makeStorageMigrator) {
    self.makeMigrator = makeMigrator
  }

  func migrateSavedData() async throws -> MovieFolderStorageMigrationReport {
    let migrationTask = Task.detached(priority: .utility) {
      defer { MovieFolderEnvironment.notifyConfigurationChanged() }
      let migrator = try makeMigrator()

      return try migrator.migrate()
    }

    return try await withTaskCancellationHandler {
      try await migrationTask.value
    } onCancel: { migrationTask.cancel() }
  }
}

extension MovieFolderStorageMigrationReport {
  /// Explains actual work without implying that absent collection results were manufactured.
  var completionMessage: String {
    let result = migratedRecordCount == 0
      ? "Saved data is already up to date."
      : "Upgraded \(migratedRecordCount) saved records. Their original data was backed up before replacement."
    let unchanged = " \(skippedCurrentRecordCount) existing records already used the current format."
    let absent = missingCollectionOutcomeRecordCount == 0 ? ""
      : " \(missingCollectionOutcomeRecordCount) "
        + (missingCollectionOutcomeRecordCount == 1 ? "collection had" : "collections had")
        + " no saved results to upgrade."

    let operational = missingOperationalRecordCount == 0 ? ""
      : " \(missingOperationalRecordCount) collections had no saved processing decisions to upgrade."

    return result + unchanged + absent + operational
      + " Movie folders and poster icons were not modified by this migration."
  }
}
