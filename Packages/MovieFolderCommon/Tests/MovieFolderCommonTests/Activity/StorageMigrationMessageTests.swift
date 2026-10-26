import Foundation
import MovieFolderCommon
import Testing

/// Migration errors identify the required recovery action without leaking raw stored fields.
struct StorageMigrationMessageTests {
  /// Older formats direct the user to the actual menu command instead of filesystem permissions.
  @Test func migrationRequiredNamesTheRecoveryCommand() {
    let error = MovieFolderStorageMigrationError.migrationRequired(record: .settings, version: 3)
    #expect(error.localizedDescription.contains("Migrate Saved Data"))
    #expect(!error.localizedDescription.contains("signed build"))
    #expect(!error.localizedDescription.contains("permissions"))
  }

  /// Finder and manual operation events preserve a migration-specific cause.
  @Test func activityExplainsMigrationInsteadOfUnknownStorageFailure() {
    let error = MovieFolderStorageMigrationError.migrationRequired(record: .settings, version: 3)
    let failure = MovieFolderActivityLogEvent.failureEvidence(for: error)
    let event = MovieFolderActivityLogEvent(action: .automaticProcessing, status: .failed, failure: failure)
    #expect(failure.reason != .unknown)
    #expect(event.text.contains("Migrate Saved Data"))
  }
}
