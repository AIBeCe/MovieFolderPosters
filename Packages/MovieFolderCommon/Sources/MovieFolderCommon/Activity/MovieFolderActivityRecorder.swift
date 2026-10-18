import Foundation
import Log
import OSLog

/// Required retained collaborator announcing committed changes without event payloads.
nonisolated public protocol MovieFolderActivityChangeNotifying: Sendable {
  /// Announces a successful append or clear after storage has committed.
  func movieFolderActivityDidChange()
}

/// The narrow activity interface shared by producer boundaries and the host history model.
nonisolated public protocol MovieFolderActivityServicing: Sendable {
  /// Records an event without throwing into product operations.
  /// - Parameter event: A typed event containing only the approved vocabulary and opaque identifiers.
  /// - Returns: Whether storage committed the event; logging failure must not replace the product result.
  @discardableResult func record(_ event: MovieFolderActivityEvent) async -> Bool
  /// Reports a logging write failure observed by this retained process-local recorder.
  /// - Returns: Whether this recorder has observed a write failure; this is separate from read or clear errors.
  var hasObservedWriteFailure: Bool { get async }
  /// Loads actual committed retained history.
  /// - Returns: Retained entries in increasing commit sequence, independent of occurrence timestamps.
  /// - Throws: Explicit storage, corruption, or unsupported-version failures.
  func entries() async throws -> [MovieFolderActivityEntry]
  /// Clears only activity history, preserving sequence and all other application storage.
  /// - Throws: Explicit storage, corruption, or unsupported-version failures.
  func clear() async throws
}

/// Opens typed activity storage lazily so unavailable logging never prevents authorized product work.
///
/// The caller supplies the dedicated directory and a strongly retained, payload-free notification publisher.
/// App Group lookup, entitlements, and notification transport belong to signed-target composition.
/// Each successful append or clear publishes an invalidation hint; readers must load committed storage.
public actor MovieFolderActivityRecorder: MovieFolderActivityServicing {
  /// Dedicated activity storage root; never serialized into an event.
  private let directory: URL
  /// Strongly retained committed-change publisher.
  private let notifier: any MovieFolderActivityChangeNotifying
  /// Successfully opened generic log, shared by operations in this process.
  private var log: ActivityLog<MovieFolderActivityEvent>?
  /// Sticky safe failure evidence, independent of product operation success or error.
  private var didObserveWriteFailure = false
  /// Safe diagnostics that contain no underlying error, path, or payload.
  private let logger = Logger(subsystem: "dag.fikios.MovieFolderPosters", category: "Activity")

  /// Configures lazy storage with a required retained notification collaborator.
  /// - Parameters:
  ///   - directory: Dedicated caller-owned activity directory.
  ///   - notifier: Payload-free invalidation publisher retained for the recorder lifetime.
  public init(directory: URL, notifier: any MovieFolderActivityChangeNotifying) {
    self.directory = directory
    self.notifier = notifier
  }

  /// Awaits a best-effort bounded write independently of the producer's cancellation.
  ///
  /// This allows terminal cancellation events to be recorded without changing the producer's original result.
  /// Failure is remembered by this recorder and returns `false`; no raw error or event data is logged.
  /// - Parameter event: The privacy-safe product event to append.
  /// - Returns: Whether the event was committed and the notifier was called.
  public func record(_ event: MovieFolderActivityEvent) async -> Bool {
    do {
      // Terminal cancellation is useful activity evidence. The bounded append must not inherit the
      // producer's cancellation, while the product operation keeps its original cancellation result.
      _ = try await Task.detached(priority: .utility) {
        let storage = try await self.storage()

        return try await storage.append(event: event)
      }.value
      notifier.movieFolderActivityDidChange()

      return true
    } catch {
      didObserveWriteFailure = true
      logger.error("Activity write failed; the product operation result is unchanged")

      return false
    }
  }

  public var hasObservedWriteFailure: Bool { get async { didObserveWriteFailure } }

  public func entries() async throws -> [MovieFolderActivityEntry] {
    let storage = try await storage()

    return try await storage.entries().map {
      MovieFolderActivityEntry(id: $0.id, sequence: $0.sequence, occurredAt: $0.occurredAt, event: $0.event)
    }
  }

  public func clear() async throws {
    let storage = try await storage()
    try await storage.clear()
    notifier.movieFolderActivityDidChange()
  }

  /// Opens the dedicated namespace, caching only successful initialization.
  private func storage() async throws -> ActivityLog<MovieFolderActivityEvent> {
    if let log { return log }
    let opened = try await ActivityLog<MovieFolderActivityEvent>(
      directory: directory, namespace: "movie-activity", maximumEntries: 500)
    log = opened

    return opened
  }
}

/// Test or alternative services may omit failure tracking when they return each write result directly.
extension MovieFolderActivityServicing {
  /// Supplies the default absence of process-local failure tracking for alternative implementations.
  /// - Returns: `false`; implementations with retained write-failure evidence can override this default.
  public var hasObservedWriteFailure: Bool { get async { false } }
}
