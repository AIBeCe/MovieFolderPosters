import Foundation
import Log
import Network

/// Optional terminal request history; storage failures never replace provider operation results.
nonisolated public protocol MovieFolderNetworkHistoryServicing: Sendable {
  /// Loads retained entries in increasing commit order.
  /// - Returns: Actual committed entries, independent of occurrence timestamp order.
  /// - Throws: Storage access, corruption, or unsupported-schema failures.
  func entries() async throws -> [MovieFolderNetworkHistoryEntry]
  /// Clears all retained network entries, including entries hidden by presentation filters.
  /// - Throws: Storage access, corruption, or unsupported-schema failures.
  func clear() async throws
  /// Reads the currently persisted recording choice.
  var isNetworkHistoryRecordingEnabled: Bool { get async throws }
  /// Saves recording choice without deleting retained entries or changing product generations.
  /// - Parameter enabled: Whether new eligible HTTP attempts may be retained.
  /// - Throws: Shared settings access or persistence failures.
  func setNetworkHistoryRecordingEnabled(_ enabled: Bool) async throws
  /// Sticky evidence of actual history storage failures, excluding intentional policy omissions.
  var hasObservedWriteFailure: Bool { get async }
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
    purpose: TMDbRequestPurpose, result: TMDbRequestResult, completedAt: Date,
    expectedNetworkHistoryConfigurationRevision: UUID, collectionID: UUID?
  ) async
}

/// Retained payload-free notifications sent only after shared accesses are released.
nonisolated public protocol MovieFolderNetworkHistoryChangeNotifying: Sendable {
  /// Announces committed network history changes.
  func movieFolderNetworkHistoryDidChange()
  /// Announces committed history configuration changes.
  func movieFolderHistoryConfigurationDidChange()
}

/// Internal outcome of an optional network history append, separate from provider results.
private enum NetworkHistoryAppendResult: Sendable {
  /// The terminal event was durably committed.
  case appended
  /// Current policy or unreadable configuration intentionally omitted the event.
  case omitted
  /// Actual history storage initialization or append failed.
  case failed
}

/// Shared bounded request history with configuration access held through an immediate append.
public actor MovieFolderNetworkHistoryService: MovieFolderNetworkHistoryServicing {
  /// Dedicated storage directory, never included in event payloads.
  private let directory: URL
  /// Shared settings controlling optional recording and collection privacy.
  private let configurationRepository: ConfigurationRepository
  /// Optional retained publisher; environment composition supplies cross-process delivery.
  private let notifier: (any MovieFolderNetworkHistoryChangeNotifying)?
  /// Successfully initialized storage; opened before acquiring settings access.
  private var cachedNetworkHistoryStore: ActivityLog<MovieFolderNetworkHistoryEvent>?
  /// Actual storage write failure evidence for this service lifetime.
  private var didObserveWriteFailure = false

  /// Creates lazy history independent of product operation admission.
  /// - Parameters:
  ///   - directory: Dedicated caller-owned bounded history location.
  ///   - configurationRepository: Shared repository required for every optional network write.
  ///   - notifier: Retained payload-free publisher, or absence in controlled tests.
  public init(
    directory: URL, configurationRepository: ConfigurationRepository,
    notifier: (any MovieFolderNetworkHistoryChangeNotifying)? = .none
  ) {
    self.directory = directory
    self.configurationRepository = configurationRepository
    self.notifier = notifier
  }

  public var hasObservedWriteFailure: Bool { didObserveWriteFailure }
  public var isNetworkHistoryRecordingEnabled: Bool {
    get throws { try configurationRepository.read().isNetworkHistoryRecordingEnabled }
  }

  public func setNetworkHistoryRecordingEnabled(_ enabled: Bool) throws {
    try configurationRepository.update { $0.isNetworkHistoryRecordingEnabled = enabled }
    notifier?.movieFolderHistoryConfigurationDidChange()
  }

  public func entries() async throws -> [MovieFolderNetworkHistoryEntry] {
    let networkHistoryStore = try await openNetworkHistoryStore()

    return try await networkHistoryStore.entries().map {
      MovieFolderNetworkHistoryEntry(id: $0.id, sequence: $0.sequence, occurredAt: $0.occurredAt, event: $0.event)
    }
  }

  public func clear() async throws {
    let networkHistoryStore = try await openNetworkHistoryStore()
    try await networkHistoryStore.clear()
    notifier?.movieFolderNetworkHistoryDidChange()
  }

  public func prepareNetworkHistoryRecording(collectionID: UUID?) async -> UUID? {
    do {
      // Initialization can perform filesystem work and must precede configuration access.
      _ = try await openNetworkHistoryStore()
    } catch {
      didObserveWriteFailure = true

      return .none
    }

    guard let currentConfiguration = try? configurationRepository.read(),
      canRecordNetworkHistory(for: currentConfiguration, collectionID: collectionID)
    else {
      return .none
    }

    return currentConfiguration.networkHistoryConfigurationRevision
  }

  public func recordCompletedNetworkRequest(
    purpose: TMDbRequestPurpose, result: TMDbRequestResult, completedAt: Date,
    expectedNetworkHistoryConfigurationRevision: UUID, collectionID: UUID?
  ) async {
    // Cancellation is itself terminal evidence. Do not inherit the producer's cancelled task for the append.
    let appendResult = await Task.detached(priority: .utility) {
      await self.appendNetworkHistoryEvent(purpose: purpose, result: result, completedAt: completedAt,
        expectedNetworkHistoryConfigurationRevision: expectedNetworkHistoryConfigurationRevision,
        collectionID: collectionID)
    }.value
    if appendResult == .appended { notifier?.movieFolderNetworkHistoryDidChange() }
  }

  /// Opens storage, then holds settings only for a single nonwaiting history commit.
  private func appendNetworkHistoryEvent(
    purpose: TMDbRequestPurpose, result: TMDbRequestResult, completedAt: Date,
    expectedNetworkHistoryConfigurationRevision: UUID, collectionID: UUID?
  ) async -> NetworkHistoryAppendResult {
    let networkHistoryStore: ActivityLog<MovieFolderNetworkHistoryEvent>
    do { networkHistoryStore = try await self.openNetworkHistoryStore() } catch {
      didObserveWriteFailure = true
      return .failed
    }

    // Busy, unreadable, or invalid settings are intentional omissions rather than history write errors.
    guard let (currentConfiguration, configurationPersistenceAccess) = try? configurationRepository.readHoldingAccess()
    else { return .omitted }

    guard currentConfiguration.networkHistoryConfigurationRevision == expectedNetworkHistoryConfigurationRevision,
      canRecordNetworkHistory(for: currentConfiguration, collectionID: collectionID)
    else {
      withExtendedLifetime(configurationPersistenceAccess) {}
      return .omitted
    }

    let appendResult: NetworkHistoryAppendResult
    do {
      try await networkHistoryStore.append(event: MovieFolderNetworkHistoryEvent(
        purpose: purpose, result: result, collectionID: collectionID), occurredAt: completedAt, accessMode: .immediate)
      appendResult = .appended
    } catch {
      didObserveWriteFailure = true
      appendResult = .failed
    }
    // The access must be gone before notifying observers, which may immediately read configuration.
    withExtendedLifetime(configurationPersistenceAccess) {}

    return appendResult
  }

  /// Evaluates the current persisted policy without touching required product outcomes.
  private func canRecordNetworkHistory(for currentConfiguration: DirectoryConfiguration, collectionID: UUID?) -> Bool {
    guard currentConfiguration.isNetworkHistoryRecordingEnabled else { return false }

    guard let collectionID else { return true }

    return currentConfiguration.directories.contains { $0.id == collectionID && !$0.usesPrivateHistory }
  }

  /// Caches successful opening of the independent bounded namespace.
  private func openNetworkHistoryStore() async throws -> ActivityLog<MovieFolderNetworkHistoryEvent> {
    if let cachedNetworkHistoryStore { return cachedNetworkHistoryStore }
    let networkHistoryStore = try await ActivityLog<MovieFolderNetworkHistoryEvent>(
      directory: directory, namespace: "movie-network", maximumEntries: 500)
    cachedNetworkHistoryStore = networkHistoryStore

    return networkHistoryStore
  }
}

/// Binds one provider client to global or collection-scoped request history without retaining requests.
nonisolated public struct MovieFolderNetworkRequestRecorder: TMDbClientRequestDelegate {
  /// Required optional-history service retained for the provider client's lifetime.
  private let networkHistoryService: any MovieFolderNetworkHistoryServicing
  /// Configured collection identity, or absence for application-wide diagnostics.
  private let collectionID: UUID?

  /// Creates a contextual delegate with no request-specific details.
  /// - Parameters:
  ///   - networkHistoryService: Optional history service retained throughout the provider client's lifetime.
  ///   - collectionID: Existing collection identity, or absence for global credential diagnostics.
  public init(networkHistoryService: any MovieFolderNetworkHistoryServicing, collectionID: UUID? = .none) {
    self.networkHistoryService = networkHistoryService
    self.collectionID = collectionID
  }

  public func tmdbClientWillSendRequest(purpose: TMDbRequestPurpose) async -> UUID? {
    await networkHistoryService.prepareNetworkHistoryRecording(collectionID: collectionID)
  }

  public func tmdbClientDidCompleteRequest(
    purpose: TMDbRequestPurpose, result: TMDbRequestResult, completedAt: Date, recordingTicket: UUID
  ) async {
    await networkHistoryService.recordCompletedNetworkRequest(
      purpose: purpose, result: result, completedAt: completedAt,
      expectedNetworkHistoryConfigurationRevision: recordingTicket, collectionID: collectionID)
  }
}
