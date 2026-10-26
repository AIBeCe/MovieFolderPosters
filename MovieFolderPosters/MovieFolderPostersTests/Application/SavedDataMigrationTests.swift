import Foundation
import MovieFolderCommon
import Synchronization
import Testing

@testable import MovieFolderPosters

/// Controlled migration results avoid opening the user's real application storage.
nonisolated final class SavedDataMigrationProbe: SavedDataMigrationServicing, Sendable {
  /// Immutable actual counts returned by this isolated service.
  private let report: MovieFolderStorageMigrationReport
  /// Safe failure injected after command admission.
  private let failure: MovieFolderStorageMigrationError?
  /// Whether the operation waits for the test to release it.
  private let holdsOperation: Bool
  /// Mutable command evidence protected independently of the UI executor.
  private struct OperationState: Sendable {
    /// Number of admitted service operations.
    var callCount = Int.zero
    /// Pending operation continuation used to verify single-flight admission.
    var continuation: CheckedContinuation<Void, Never>?
  }
  /// Protects the service's cross-executor evidence and suspension.
  private let operationState = Mutex(OperationState())
  /// Number of admitted service operations.
  var callCount: Int { operationState.withLock { $0.callCount } }

  /// Retains deterministic results and optional operation suspension.
  init(failure: MovieFolderStorageMigrationError? = .none, holdsOperation: Bool = false) {
    report = MovieFolderStorageMigrationReport(migratedRecordCount: 2, skippedCurrentRecordCount: 1,
      missingCollectionOutcomeRecordCount: 0)
    self.failure = failure
    self.holdsOperation = holdsOperation
  }

  func migrateSavedData() async throws -> MovieFolderStorageMigrationReport {
    operationState.withLock { $0.callCount += 1 }
    if holdsOperation {
      await withCheckedContinuation { continuation in
        operationState.withLock { $0.continuation = continuation }
      }
    }
    if let failure { throw failure }

    return report
  }

  /// Allows one suspended operation to return its controlled result.
  func release() {
    let continuation = operationState.withLock {
      let continuation = $0.continuation
      $0.continuation = .none

      return continuation
    }
    continuation?.resume()
  }
}

/// The command's report accurately distinguishes upgrades from current or absent records.
@Test func savedDataMigrationReportUsesActualCounts() {
  let report = MovieFolderStorageMigrationReport(migratedRecordCount: 2, skippedCurrentRecordCount: 3,
    missingCollectionOutcomeRecordCount: 1)
  #expect(report.completionMessage.contains("Upgraded 2 saved records"))
  #expect(report.completionMessage.contains("3 existing records"))
  #expect(report.completionMessage.contains("1 collection had no saved results"))
  let current = MovieFolderStorageMigrationReport(migratedRecordCount: 0, skippedCurrentRecordCount: 4,
    missingCollectionOutcomeRecordCount: 0)
  #expect(current.completionMessage.contains("already up to date"))
}
