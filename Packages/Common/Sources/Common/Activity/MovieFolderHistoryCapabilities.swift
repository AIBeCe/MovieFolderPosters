import Foundation

/// Records typed activity without participating in product admission.
nonisolated public protocol MovieFolderActivityRecording: Sendable {
  /// Records an event without throwing into product operations.
  /// - Parameter event: A typed event containing only the approved vocabulary and opaque identifiers.
  /// - Returns: Whether recording succeeded or privacy intentionally omitted it; false means an actual storage failure.
  @discardableResult func record(_ event: MovieFolderActivityLogEvent) async -> Bool
  /// Records a committed removal with its repository-minted historical name and capture-time privacy.
  /// - Parameter receipt: Evidence returned only after the repository removal succeeds.
  /// - Returns: Successful handling, including intentional omission, or false for an actual history write failure.
  @discardableResult func recordCollectionRemoval(_ receipt: CommittedCollectionRemoval) async -> Bool
}

/// Reads retained activity in commit order.
nonisolated public protocol MovieFolderActivityReading: Sendable {
  /// Loads actual committed retained history.
  /// - Returns: Retained entries in increasing commit sequence, independent of occurrence timestamps.
  /// - Throws: Explicit storage, corruption, or unsupported-version failures.
  func entries() async throws -> [MovieFolderActivityLogEntry]
}

/// Reads retained network history in commit order.
nonisolated public protocol MovieFolderNetworkHistoryReading: Sendable {
  /// Loads retained entries in increasing commit order.
  /// - Returns: Actual committed entries, independent of occurrence timestamp order.
  /// - Throws: Storage access, corruption, or unsupported-schema failures.
  func entries() async throws -> [MovieFolderNetworkHistoryEntry]
}

/// Clears the history owned by the receiving service.
nonisolated public protocol MovieFolderHistoryClearing: Sendable {
  /// Clears retained entries while preserving the commit sequence.
  func clear() async throws
}

/// Reports process-local history write failures.
nonisolated public protocol MovieFolderHistoryWriteFailureReporting: Sendable {
  /// Reports a logging write failure observed by this retained process-local recorder.
  /// - Returns: Whether this recorder has observed a write failure; this is separate from read or clear errors.
  var hasObservedWriteFailure: Bool { get async }
}

/// Reads and writes the optional network history preference.
nonisolated public protocol MovieFolderNetworkHistorySettings: Sendable {
  /// Reads the currently persisted recording choice.
  var isNetworkHistoryRecordingEnabled: Bool { get async throws }
  /// Saves recording choice without deleting retained entries or changing product generations.
  /// - Parameter enabled: Whether new eligible HTTP attempts may be retained.
  /// - Throws: Shared settings access or persistence failures.
  func setNetworkHistoryRecordingEnabled(_ enabled: Bool) async throws
}

/// Prepares and records eligible terminal network observations.
nonisolated public protocol MovieFolderNetworkHistoryRecording: Sendable {
  /// Captures a history-only revision before dispatch, without retaining configuration access over network work.
  /// - Parameter collectionID: Collection context, or absence for application-wide requests.
  /// - Returns: An opaque revision ticket, or absence when recording cannot be prepared.
  func prepareNetworkHistoryRecording(collectionID: UUID?) async -> UUID?
  /// Appends only if the current revision, recording choice, and collection privacy still permit it.
  /// - Parameters:
  ///   - purpose: Closed category of the dispatched HTTP attempt.
  ///   - result: Terminal HTTP evidence, never a product decoding or matching result.
  ///   - completedAt: Finite terminal observation timestamp.
  ///   - expectedNetworkHistoryConfigurationRevision: Opaque ticket captured before this attempt was dispatched.
  ///   - collectionID: The same collection context used when preparing the ticket.
  func recordCompletedNetworkRequest(
    purpose: MovieNetworkRequestCategory, result: MovieNetworkRequestResult, completedAt: Date,
    expectedNetworkHistoryConfigurationRevision: UUID, collectionID: UUID?
  ) async
}
