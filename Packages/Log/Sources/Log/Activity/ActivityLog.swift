import Foundation
import Persistence

/// Controls whether an append retries another writer's cross-process history access.
public enum ActivityLogAppendAccessMode: Sendable {
  /// Retry contention within the existing bounded window.
  case boundedWait
  /// Attempt access once, without waiting while another service access is held.
  case immediate
}

/// A bounded, typed activity history shared by cooperating processes.
///
/// Use a dedicated directory and stable namespace for each history. Payload types own their schema and
/// privacy rules. This service does not render messages or collect system diagnostic logs.
/// Reads, clears, and default appends retry cancellation-aware contention for approximately one second.
/// Immediate appends attempt once when the caller must not wait while holding another service access.
/// Filesystem work runs outside the caller's actor; no access spans provider work.
/// Callers supply storage authorization and coordinate change notifications separately.
public struct ActivityLog<Event: Codable & Sendable>: Sendable {
  /// The store whose record envelope is limited to 2 MiB.
  private let store: PersistenceStore
  /// The fixed opaque key binding the caller namespace to this history.
  private let key: String
  /// The number of most recently committed entries to retain.
  private let maximumEntries: Int

  /// Opens a history away from the caller's actor.
  ///
  /// - Parameters:
  ///   - directory: A dedicated history directory opened by Persistence without following symlinks.
  ///   - namespace: A nonempty stable identifier; callers must use the same event schema for this identifier.
  ///   - maximumEntries: Retained entry limit, from 1 through 500; defaults to 500.
  /// - Throws: A configuration, cancellation, or persistence error.
  public init(directory: URL, namespace: String, maximumEntries: Int = 500) async throws {
    guard !namespace.isEmpty else { throw ActivityLogError.invalidNamespace }
    guard (1...500).contains(maximumEntries) else { throw ActivityLogError.invalidRetentionLimit }
    store = try await Self.offActor { try PersistenceStore(directory: directory, maximumRecordBytes: 2 * 1024 * 1024) }
    key = "Log.Activity.v1." + namespace
    self.maximumEntries = maximumEntries
  }

  /// Atomically commits an event, trims oldest entries, and returns its durable identity and order.
  ///
  /// Encoded events are limited to 2 KiB. Cancellation before the commit prevents change; cancellation
  /// arriving after the final cancellation check may race with the atomic commit.
  /// - Parameters:
  ///   - event: The caller-defined Codable payload, whose encoded size must not exceed 2 KiB.
  ///   - occurredAt: A finite observation timestamp; this does not determine the committed order.
  ///   - accessMode: Bounded retry by default, or a single immediate attempt when holding another service access.
  /// - Returns: The committed entry, including its stable identity and increasing sequence.
  /// - Throws: Validation, corruption, unsupported-version, contention, cancellation, or persistence errors.
  @discardableResult
  public func append(
    event: Event, occurredAt: Date = Date(), accessMode: ActivityLogAppendAccessMode = .boundedWait
  ) async throws -> ActivityEntry<Event> {
    try await Self.offActor {
      try Self.validate(event)
      guard occurredAt.timeIntervalSinceReferenceDate.isFinite else { throw ActivityLogError.invalidOccurrenceTime }
      let persistenceAccess = try await acquireAccess(mode: accessMode)
      var activityHistoryRecord = try readActivityHistory(using: persistenceAccess)
      guard activityHistoryRecord.lastSequence < UInt64.max else { throw ActivityLogError.sequenceExhausted }
      let entry = ActivityEntry(
        id: UUID(), sequence: activityHistoryRecord.lastSequence + 1, occurredAt: occurredAt, event: event)
      activityHistoryRecord.lastSequence = entry.sequence
      activityHistoryRecord.entries.append(entry)
      activityHistoryRecord.entries = Array(activityHistoryRecord.entries.suffix(maximumEntries))
      let encoded = try JSONEncoder().encode(activityHistoryRecord)
      try Task.checkCancellation()
      try persistenceAccess.write(encoded)

      return entry
    }
  }

  /// Reads retained entries in oldest-to-newest commit order, under the same access used by mutations.
  ///
  /// Corrupt, unsupported, oversized, and unavailable records fail explicitly and remain unchanged.
  /// - Returns: Retained entries ordered by sequence, independent of their occurrence timestamps.
  /// - Throws: Validation, corruption, unsupported-version, contention, cancellation, or persistence errors.
  public func entries() async throws -> [ActivityEntry<Event>] {
    try await Self.offActor {
      let persistenceAccess = try await acquireAccess()

      return try readActivityHistory(using: persistenceAccess).entries
    }
  }

  /// Atomically clears entries while preserving the latest committed sequence and reusable lock file.
  ///
  /// A corrupt or unsupported activity history record cannot be cleared because its sequence cannot be recovered
  /// reliably. Such a failure remains explicit and leaves the record unchanged.
  /// This operation affects only this history's record; it does not remove unrelated persistence records.
  /// - Throws: Validation, corruption, unsupported-version, contention, cancellation, or persistence errors.
  public func clear() async throws {
    try await Self.offActor {
      let persistenceAccess = try await acquireAccess()
      var activityHistoryRecord = try readActivityHistory(using: persistenceAccess)
      activityHistoryRecord.entries.removeAll()
      let encoded = try JSONEncoder().encode(activityHistoryRecord)
      try Task.checkCancellation()
      try persistenceAccess.write(encoded)
    }
  }

  /// Acquires one cross-process access, retrying for at most approximately one second.
  private func acquireAccess(mode: ActivityLogAppendAccessMode = .boundedWait) async throws -> PersistenceAccess {
    let maximumAttempt = mode == .immediate ? 0 : 100
    for attempt in 0...maximumAttempt {
      try Task.checkCancellation()
      if let persistenceAccess = try store.acquireAccess(for: key) { return persistenceAccess }
      guard attempt < maximumAttempt else { throw ActivityLogError.accessTimedOut }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw ActivityLogError.accessTimedOut
  }

  /// Decodes and validates the complete activity history record before any operation uses or replaces it.
  private func readActivityHistory(using persistenceAccess: PersistenceAccess) throws -> ActivityHistoryRecord<Event> {
    guard let data = try persistenceAccess.read() else { return ActivityHistoryRecord() }
    let activityHistoryRecord: ActivityHistoryRecord<Event>
    do {
      activityHistoryRecord = try JSONDecoder().decode(ActivityHistoryRecord<Event>.self, from: data)
    } catch {
      throw ActivityLogError.corruptActivityHistory
    }
    guard activityHistoryRecord.version == 1 else { throw ActivityLogError.unsupportedVersion }
    guard activityHistoryRecord.entries.count <= 500 else { throw ActivityLogError.corruptActivityHistory }
    var previousSequence = UInt64.zero
    var identities = Set<UUID>()
    for entry in activityHistoryRecord.entries {
      guard entry.sequence > previousSequence, entry.sequence <= activityHistoryRecord.lastSequence,
        entry.occurredAt.timeIntervalSinceReferenceDate.isFinite, identities.insert(entry.id).inserted
      else { throw ActivityLogError.corruptActivityHistory }
      try Self.validate(entry.event)
      previousSequence = entry.sequence
    }
    guard activityHistoryRecord.entries.isEmpty || previousSequence == activityHistoryRecord.lastSequence else {
      throw ActivityLogError.corruptActivityHistory
    }

    return activityHistoryRecord
  }

  /// Rejects unbounded event payloads before acquiring a change access.
  private static func validate(_ event: Event) throws {
    guard try JSONEncoder().encode(event).count <= 2 * 1024 else { throw ActivityLogError.eventTooLarge }
  }

  /// Keeps synchronous filesystem work off UI actors and forwards cancellation to detached work.
  private static func offActor<Result: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Result
  ) async throws -> Result {
    try Task.checkCancellation()
    let task = Task.detached {
      try Task.checkCancellation()

      return try await operation()
    }

    return try await withTaskCancellationHandler {
      try Task.checkCancellation()

      return try await task.value
    } onCancel: { task.cancel() }
  }
}

/// The private versioned payload within Persistence's bounded record envelope.
private struct ActivityHistoryRecord<Event: Codable & Sendable>: Codable, Sendable {
  /// The activity payload schema version.
  var version = 1
  /// The latest committed sequence, retained even when history is cleared.
  var lastSequence = UInt64.zero
  /// Retained events in increasing commit order.
  var entries = [ActivityEntry<Event>]()
}
