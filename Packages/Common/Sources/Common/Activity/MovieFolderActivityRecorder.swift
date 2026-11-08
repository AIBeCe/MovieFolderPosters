import Foundation
import Log
import OSLog
import Persistence

/// Required retained collaborator announcing committed changes without event payloads.
nonisolated public protocol MovieFolderActivityChangeNotifying: Sendable {
  /// Announces a successful append or clear after storage has committed.
  func movieFolderActivityDidChange()
}

/// Complete activity capabilities retained by application composition.
nonisolated public protocol MovieFolderActivityServicing: MovieFolderActivityRecording, MovieFolderActivityReading,
  MovieFolderHistoryClearing, MovieFolderHistoryWriteFailureReporting {}

/// Internal result of successful activity handling; storage errors remain thrown failures.
private enum ActivityHistoryAppendResult: Sendable {
  /// The event was durably committed.
  case appended
  /// Privacy policy intentionally omitted the event.
  case omitted
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
  /// Required in production; explicit legacy test construction may omit privacy configuration.
  private let configurationRepository: ConfigurationRepository?
  /// Store-opening authorization retained for this recorder's lazy history initialization.
  private let storeFactory: PersistenceStoreFactory
  /// Successfully opened generic history store, shared by operations in this process.
  private var cachedActivityHistoryStore: ActivityLog<MovieFolderActivityLogEvent>?
  /// Sticky safe failure evidence, independent of product operation success or error.
  private var didObserveWriteFailure = false
  /// Safe diagnostics that contain no underlying error, path, or payload.
  private let logger = Logger(subsystem: "dag.fikios.MovieFolderPosters", category: "Activity")

  /// Configures lazy storage with a required retained notification collaborator.
  /// - Parameters:
  ///   - directory: Dedicated caller-owned activity directory.
  ///   - notifier: Payload-free invalidation publisher retained for the recorder lifetime.
  ///   - configurationRepository: Shared privacy repository required in production; absence supports controlled tests.
  ///   - storeFactory: Path authorization used when the history store is opened lazily.
  public init(
    directory: URL, notifier: any MovieFolderActivityChangeNotifying,
    configurationRepository: ConfigurationRepository? = .none,
    storeFactory: PersistenceStoreFactory = PersistenceStoreFactory()
  ) {
    self.directory = directory
    self.notifier = notifier
    self.configurationRepository = configurationRepository
    self.storeFactory = storeFactory
  }

  /// Awaits a best-effort bounded write independently of the producer's cancellation.
  ///
  /// This allows terminal cancellation events to be recorded without changing the producer's original result.
  /// Failure is remembered by this recorder and returns `false`; no raw error or event data is logged.
  /// - Parameter event: The privacy-safe product event to append.
  /// - Returns: True for a committed event or intentional privacy omission; false for an actual storage failure.
  public func record(_ event: MovieFolderActivityLogEvent) async -> Bool {
    await recordActivityEvent(event, committedRemoval: .none)
  }

  public func recordCollectionRemoval(_ receipt: CommittedCollectionRemoval) async -> Bool {
    let activityLogContext = MovieFolderActivityLogContext(removal: receipt)
    let event = activityLogContext.event(action: .collectionRemoved, status: .succeeded)

    return await recordActivityEvent(event, committedRemoval: receipt)
  }

  /// Preserves terminal cancellation evidence independently of the producer's task cancellation.
  private func recordActivityEvent(
    _ event: MovieFolderActivityLogEvent, committedRemoval: CommittedCollectionRemoval?
  ) async -> Bool {
    do {
      let appendResult = try await Task.detached(priority: .utility) {
        try await self.appendActivityEvent(event, committedRemoval: committedRemoval)
      }.value
      if appendResult == .appended { notifier.movieFolderActivityDidChange() }

      return true
    } catch {
      didObserveWriteFailure = true
      logger.error("Activity write failed; the product operation result is unchanged")

      return false
    }
  }

  /// Opens history before settings, then keeps settings stable through one nonwaiting append.
  private func appendActivityEvent(
    _ event: MovieFolderActivityLogEvent, committedRemoval: CommittedCollectionRemoval?
  ) async throws -> ActivityHistoryAppendResult {
    let activityHistoryStore = try await openActivityHistoryStore()
    let collectionID = committedRemoval?.collectionID ?? event.collectionID

    guard let collectionID else {
      let activityEventToAppend = event.target == .none ? event : event.redactingCollectionIdentifiers()
      try await appendBoundedActivityEvent(activityEventToAppend, to: activityHistoryStore, accessMode: .boundedWait)

      return .appended
    }

    guard let configurationRepository else {
      try await appendBoundedActivityEvent(event.redactingCollectionIdentifiers(),
        to: activityHistoryStore, accessMode: .boundedWait)

      return .appended
    }

    guard let (currentConfiguration, configurationPersistenceAccess) = try? configurationRepository.readHoldingAccess()
    else { return .omitted }

    let configuredDirectory = currentConfiguration.directories.first { $0.id == collectionID }
    let canRetainCollectionIdentifiers = if let committedRemoval {
      !committedRemoval.usedPrivateHistory && !(configuredDirectory?.usesPrivateHistory ?? false)
    } else {
      configuredDirectory.map { !$0.usesPrivateHistory } ?? false
    }
    let activityEventToAppend = canRetainCollectionIdentifiers ? event : event.redactingCollectionIdentifiers()
    do {
      try await appendBoundedActivityEvent(activityEventToAppend, to: activityHistoryStore, accessMode: .immediate)
      withExtendedLifetime(configurationPersistenceAccess) {}

      return .appended
    } catch {
      withExtendedLifetime(configurationPersistenceAccess) {}
      throw error
    }
  }

  /// Falls back to fixed omission evidence if complete historical names exceed the activity event limit.
  private func appendBoundedActivityEvent(
    _ event: MovieFolderActivityLogEvent, to activityHistoryStore: ActivityLog<MovieFolderActivityLogEvent>,
    accessMode: ActivityHistoryAppendAccessMode
  ) async throws {
    do {
      try await activityHistoryStore.append(event: event, accessMode: accessMode)
    } catch ActivityLogError.eventTooLarge {
      try await activityHistoryStore.append(event: event.omittingOversizedDetails(), accessMode: accessMode)
    }
  }

  public var hasObservedWriteFailure: Bool { didObserveWriteFailure }

  public func entries() async throws -> [MovieFolderActivityLogEntry] {
    let activityHistoryStore = try await openActivityHistoryStore()

    return try await activityHistoryStore.entries().map {
      MovieFolderActivityLogEntry(id: $0.id, sequence: $0.sequence, occurredAt: $0.occurredAt, event: $0.event)
    }
  }

  public func clear() async throws {
    let activityHistoryStore = try await openActivityHistoryStore()
    try await activityHistoryStore.clear()
    notifier.movieFolderActivityDidChange()
  }

  /// Opens the dedicated namespace, caching only successful initialization.
  private func openActivityHistoryStore() async throws -> ActivityLog<MovieFolderActivityLogEvent> {
    if let cachedActivityHistoryStore { return cachedActivityHistoryStore }
    let activityHistoryStore = try await ActivityLog<MovieFolderActivityLogEvent>(
      directory: directory, namespace: "movie-activity", storeFactory: storeFactory, maximumEntries: 500,
      maximumEventBytes: 8192, maximumHistoryPayloadBytes: 1024 * 1024, writerRecordVersion: 2)
    cachedActivityHistoryStore = activityHistoryStore

    return activityHistoryStore
  }
}

extension MovieFolderActivityRecording {
  /// Alternative services report a safe unlinked removal rather than pretending to retain trusted names.
  @discardableResult
  public func recordCollectionRemoval(_ receipt: CommittedCollectionRemoval) async -> Bool {
    await record(MovieFolderActivityLogEvent(action: .collectionRemoved, status: .succeeded))
  }
}

extension MovieFolderActivityServicing {
  /// Supplies the default absence of process-local failure tracking for alternative implementations.
  /// - Returns: `false`; implementations with retained write-failure evidence can override this default.
  public var hasObservedWriteFailure: Bool { false }
}
