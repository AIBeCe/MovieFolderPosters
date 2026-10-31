import Foundation
import MovieFolderCommon
import Network
import Testing

@testable import MovieFolderPosters

/// Controlled in-memory history used only by explicitly injected host tests.
final class MovieFolderActivityServiceFake: MovieFolderActivityServicing, @unchecked Sendable {
  /// Serializes fake history, failure controls, and held-read state.
  private let lock = NSLock()
  /// Retained fake committed entries.
  private var history: [MovieFolderActivityLogEntry] = []
  /// Increasing sequence preserved across Clear.
  private var sequence = UInt64.zero
  /// Failure controls independent of configuration operations.
  private var failsWrites = false
  /// Whether reads fail without revealing underlying errors.
  private var failsReads = false
  /// Whether Clear fails while preserving history.
  private var failsClear = false
  /// Continuation holding one captured read for race verification.
  private var heldRead: CheckedContinuation<Void, Never>?
  /// Whether the next read should be suspended after taking its snapshot.
  private var shouldHoldRead = false
  /// Number of reads, used to observe a suspension without a timer.
  private var storedReadCount = Int.zero
  var readCount: Int { lock.withLock { storedReadCount } }

  /// Controlled service failure without arbitrary descriptions.
  enum Failure: Error { case unavailable }

  /// Configures independent history failures.
  func setFailures(write: Bool = false, read: Bool = false, clear: Bool = false) {
    lock.withLock {
      failsWrites = write
      failsReads = read
      failsClear = clear
    }
  }

  /// Suspends the next read after snapshot capture.
  func holdNextRead() { lock.withLock { shouldHoldRead = true } }
  /// Releases the captured read.
  func releaseRead() {
    let continuation = lock.withLock {
      defer { heldRead = .none }

      return heldRead
    }
    continuation?.resume()
  }
  /// Whether a read is currently suspended.
  var isReadHeld: Bool { lock.withLock { heldRead != nil } }

  func record(_ event: MovieFolderActivityLogEvent) -> Bool {
    lock.withLock {
      guard !failsWrites else { return false }
      sequence += 1
      history.append(MovieFolderActivityLogEntry(id: UUID(), sequence: sequence, occurredAt: Date(), event: event))
      if history.count > 500 { history.removeFirst(history.count - 500) }

      return true
    }
  }

  func entries() async throws -> [MovieFolderActivityLogEntry] {
    let (snapshot, shouldHold, shouldFail) = lock.withLock {
      storedReadCount += 1
      let shouldHold = shouldHoldRead
      shouldHoldRead = false

      return (history, shouldHold, failsReads)
    }
    if shouldFail { throw Failure.unavailable }
    if shouldHold {
      await withCheckedContinuation { continuation in
        lock.withLock { heldRead = continuation }
      }
    }

    return snapshot
  }

  func clear() throws {
    try lock.withLock {
      if failsClear { throw Failure.unavailable }
      history = []
    }
  }
}

/// Verifies opening loads persisted history, Clear scope, and independent failures.
@MainActor
struct LogViewModelTests {
  /// Search and severity intersect while hidden selected rows stay deselected after clearing filters.
  @Test func safeFiltersPruneHiddenSelection() async {
    let service = MovieFolderActivityServiceFake()
    let log = LogViewModel(activityHistoryService: service)
    await log.record(MovieFolderActivityLogEvent(action: .posterRefresh, status: .failed))
    await log.record(MovieFolderActivityLogEvent(action: .applicationOpened, status: .succeeded))
    log.selectRows(IndexSet(integersIn: 0..<2))
    log.setProcessingFilters(searchText: "poster", category: "Poster Actions", severity: "Error")
    #expect(log.filteredHistoryRows().count == 1)
    #expect(log.selectedRows == IndexSet(integer: 0))
    #expect(log.textForSelectedHistoryRows().contains("Error"))
    #expect(!log.textForSelectedHistoryRows().contains(log.activityEntries[0].id.uuidString))
    log.setProcessingFilters(searchText: "", category: .none, severity: .none)
    #expect(log.selectedRows == IndexSet(integer: 0))
  }

  /// A source switch fences a suspended activity read and displays only the replacement source.
  @Test func sourceSwitchFencesSuspendedReadAndClearTargetsAllNetworkRows() async throws {
    let activity = MovieFolderActivityServiceFake()
    #expect(await activity.record(MovieFolderActivityLogEvent(action: .applicationOpened, status: .succeeded)))
    let network = NetworkHistoryPresentationFake()
    await network.append(.init(purpose: .movieSearch, result: .response(statusCode: 200)))
    await network.append(.init(purpose: .posterDownload, result: .transportFailure))
    let log = LogViewModel(activityHistoryService: activity, networkHistoryService: network)
    await activity.holdNextRead()
    let loading = Task { await log.reload() }
    while !(await activity.isReadHeld) { await Task.yield() }
    log.setSource(.network)
    await Task.yield()
    await activity.releaseRead()
    await loading.value
    #expect(log.historySource == .network)
    #expect(log.filteredHistoryRows().count == 2)
    log.selectRows(IndexSet(integersIn: 0..<2))
    log.setProcessingFilters(searchText: "Movie Search", category: .none, severity: .none)
    #expect(log.filteredHistoryRows().count == 1)
    #expect(log.textForSelectedHistoryRows().contains("HTTP response 200"))
    #expect(!log.textForSelectedHistoryRows().contains("transport failed"))
    await log.clear()
    #expect(await network.entries().isEmpty)
    #expect(try await activity.entries().count == 1)
    #expect(log.selectedRows.isEmpty)
  }

  /// Failed recording saves retain history and render the persisted choice, rather than the attempted choice.
  @Test func failedNetworkPreferenceSaveRevertsToPersistedState() async throws {
    let network = NetworkHistoryPresentationFake()
    await network.append(.init(purpose: .movieSearch, result: .response(statusCode: 200)))
    let log = LogViewModel(activityHistoryService: MovieFolderActivityServiceFake(), networkHistoryService: network)
    await log.reload()
    #expect(!log.isNetworkHistoryRecordingEnabled)
    await network.setSaveFailure(true)
    await log.setNetworkHistoryRecordingEnabled(true)
    #expect(log.hasNetworkRecordingPreferenceFailure)
    #expect(!log.isNetworkHistoryRecordingEnabled)
    #expect(await network.entries().count == 1)
    await network.setSaveFailure(false)
    await log.setNetworkHistoryRecordingEnabled(true)
    #expect(log.isNetworkHistoryRecordingEnabled)
    #expect(!log.hasNetworkRecordingPreferenceFailure)
    await log.setNetworkHistoryRecordingEnabled(false)
    #expect(await network.entries().count == 1)
  }

  /// Verifies opening the log reloads committed service history.
  @Test func openingAndReopeningLoadsActualServiceHistory() async {
    let service = MovieFolderActivityServiceFake()
    await service.record(MovieFolderActivityLogEvent(action: .applicationOpened, status: .succeeded))
    let log = LogViewModel(activityHistoryService: service)
    #expect(log.statusText.contains("Loading"))
    await log.reload()
    #expect(log.activityEntries.count == 1)
    await service.record(MovieFolderActivityLogEvent(action: .posterRefresh, status: .succeeded))
    await log.reload()
    #expect(log.activityEntries.count == 2)
  }

  /// Preserves displayed history and reports a distinct clear failure.
  @Test func clearFailureKeepsEntriesAndShowsDistinctMessage() async {
    let service = MovieFolderActivityServiceFake()
    let log = LogViewModel(activityHistoryService: service)
    await log.record(MovieFolderActivityLogEvent(action: .applicationOpened, status: .succeeded))
    await service.setFailures(clear: true)
    await log.clear()
    #expect(log.activityEntries.count == 1)
    #expect(log.hasClearFailure)
    #expect(!log.hasLoadFailure)
    #expect(log.statusText.contains("Could not clear"))
  }

  /// Verifies recording failures and history-loading failures have independent presentation state.
  @Test func failedWritesAndLoadsRemainSeparate() async {
    let service = MovieFolderActivityServiceFake()
    let log = LogViewModel(activityHistoryService: service)
    await service.setFailures(write: true)
    await log.record(MovieFolderActivityLogEvent(action: .credentialSaved, status: .succeeded))
    #expect(log.hasObservedWriteFailure)
    #expect(!log.hasLoadFailure)
    await service.setFailures(read: true)
    await log.reload()
    #expect(log.hasLoadFailure)
    #expect(!log.hasClearFailure)
  }

  /// Prevents an older read from restoring cleared history and coalesces reload notifications.
  @Test func clearFencesAnOlderCapturedReadAndCoalescesHints() async {
    let service = MovieFolderActivityServiceFake()
    await service.record(MovieFolderActivityLogEvent(action: .applicationOpened, status: .succeeded))
    let log = LogViewModel(activityHistoryService: service)
    await service.holdNextRead()
    let reload = Task { await log.reload() }
    while !(await service.isReadHeld) { await Task.yield() }
    for _ in 0..<20 { await log.reload() }
    await log.clear()
    await service.releaseRead()
    await reload.value
    #expect(log.activityEntries.isEmpty)
    #expect(!log.hasLoadFailure)
    #expect(await service.readCount == 2)
  }

  /// Rejects stale reads after failed clearing while preserving its failure message.
  @Test func failedClearFencesCapturedReadAndReloadsHistoryWithoutLosingFailure() async {
    let service = MovieFolderActivityServiceFake()
    await service.record(MovieFolderActivityLogEvent(action: .applicationOpened, status: .succeeded))
    let log = LogViewModel(activityHistoryService: service)
    await log.reload()
    await service.holdNextRead()
    let reload = Task { await log.reload() }
    while !(await service.isReadHeld) { await Task.yield() }
    await service.record(MovieFolderActivityLogEvent(action: .posterRemoval, status: .succeeded))
    await service.setFailures(clear: true)
    await log.clear()
    await service.releaseRead()
    await reload.value
    #expect(log.activityEntries.map(\.sequence) == [1, 2])
    #expect(log.hasClearFailure)
    #expect(!log.hasLoadFailure)
    #expect(log.statusText.contains("Could not clear activity history"))
    #expect(await service.readCount == 3)
  }

  /// Reloads another recorder's committed history after missed notifications.
  @Test func reopeningLoadsOtherRecorderCommitsAfterMissedChangeHints() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = MovieFolderActivityRecorder(directory: directory, notifier: IgnoredActivityChangeNotifier())
    #expect(await first.record(MovieFolderActivityLogEvent(action: .applicationOpened, status: .succeeded)))
    let log = LogViewModel(activityHistoryService: first)
    await log.reload()
    #expect(log.activityEntries.count == 1)
    let otherProcess = MovieFolderActivityRecorder(directory: directory, notifier: IgnoredActivityChangeNotifier())
    #expect(await otherProcess.record(MovieFolderActivityLogEvent(action: .automaticProcessing, status: .partial)))
    #expect(log.activityEntries.count == 1)
    await log.reload()
    #expect(log.activityEntries.map(\.sequence) == [1, 2])
    #expect(log.activityEntries.last?.event.status == .partial)
    #expect(!log.hasLoadFailure)
  }

  /// Unverified collection context retains failure evidence while omitting names and correlation identifiers.
  @Test func actualManualProducerRetainsFailureWithoutUnverifiedCollectionContext() async throws {
    let activity = MovieFolderActivityServiceFake()
    let service = MoviePosterActionService(activity: activity)
    let rootID = UUID()
    let request = MoviePosterRequest(
      rootID: rootID, childName: "private-title", identity: "private-identity", action: .change)
    let invalid = MovieMetadata(id: 0, title: "private-title", originalTitle: "private-original",
                                releaseYear: .none, posterPath: .none)
    await #expect(throws: MoviePosterActionServiceError.invalidSelection) {
      try await service.applyPoster(invalid, for: request)
    }
    let events = try await activity.entries().map(\.event)
    #expect(events.map(\.action) == [.posterSelection, .posterSelection])
    #expect(events.map(\.status) == [.started, .failed])
    #expect(events.allSatisfy { $0.activityGroupID == .none && $0.collectionID == .none && $0.target == .none })
    #expect(events.last?.failure?.reason == .invalidSelection)
    #expect(events.allSatisfy { !$0.text.contains("private") })
    await activity.setFailures(write: true)
    await #expect(throws: MoviePosterActionServiceError.invalidSelection) {
      try await service.applyPoster(invalid, for: request)
    }
  }

}

/// Deliberately drops committed hints to verify explicit persisted reload recovery.
private struct IgnoredActivityChangeNotifier: MovieFolderActivityChangeNotifying {
  func movieFolderActivityDidChange() {}
}

/// Isolated network source with explicit saved preference and failure controls.
private actor NetworkHistoryPresentationFake: MovieFolderNetworkHistoryServicing {
  /// Retained entries independent of activity storage.
  private var history: [MovieFolderNetworkHistoryEntry] = []
  /// Saved opt-in preference defaults off.
  private var enabled = false
  /// Whether preference writes fail while preserving saved state.
  private var failsSave = false
  /// Test-controlled storage failure.
  enum Failure: Error { case unavailable }
  /// Observed history failures remain independent of preference failures.
  var hasObservedWriteFailure: Bool { false }
  /// Persisted opt-in choice.
  var isNetworkHistoryRecordingEnabled: Bool { enabled }
  /// Changes preference failure injection.
  func setSaveFailure(_ fails: Bool) { failsSave = fails }
  /// Retains fixed safe evidence for source presentation tests.
  func append(_ event: MovieFolderNetworkHistoryEvent) {
    history.append(.init(id: UUID(), sequence: UInt64(history.count + 1), occurredAt: Date(), event: event))
  }
  func entries() -> [MovieFolderNetworkHistoryEntry] { history }
  func clear() { history = [] }
  func setNetworkHistoryRecordingEnabled(_ enabled: Bool) throws {
    if failsSave { throw Failure.unavailable }
    self.enabled = enabled
  }
  func prepareNetworkHistoryRecording(collectionID: UUID?) -> UUID? { .none }
  func recordCompletedNetworkRequest(
    purpose: TMDbRequestCategory, result: TMDbRequestCompletionResult, completedAt: Date,
    expectedNetworkHistoryConfigurationRevision: UUID, collectionID: UUID?
  ) {}
}
