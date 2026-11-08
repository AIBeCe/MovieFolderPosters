import Foundation

/// Outcome of retrying one selected folder without starting a collection traversal.
nonisolated public enum FolderRetryResult: Sendable, Equatable {
  /// One eligible attempt completed; provider admission can require stopping the remaining selection.
  case attempted(ProcessingSummary, stopSelection: Bool)
  /// Current folder evidence requires another action or no longer matches the captured selection.
  case notEligible
  /// A current retry boundary prevents attempting the folder before the given date.
  case waiting(until: Date)
}
