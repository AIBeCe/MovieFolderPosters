import Foundation
import MovieFolderCommon
import Network
import Testing

@testable import MovieFolderPosters

/// Controlled in-memory history used only by explicitly injected host tests.
actor ActivityServiceFake: MovieFolderActivityServicing {
  /// Retained fake committed entries.
  private var history: [MovieFolderActivityEntry] = []
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
  private(set) var readCount = Int.zero

  /// Controlled service failure without arbitrary descriptions.
  enum Failure: Error { case unavailable }

  /// Configures independent history failures.
  func setFailures(write: Bool = false, read: Bool = false, clear: Bool = false) {
    failsWrites = write
    failsReads = read
    failsClear = clear
  }

  /// Suspends the next read after snapshot capture.
  func holdNextRead() { shouldHoldRead = true }
  /// Releases the captured read.
  func releaseRead() { heldRead?.resume(); heldRead = .none }
  /// Whether a read is currently suspended.
  var isReadHeld: Bool { heldRead != nil }

  func record(_ event: MovieFolderActivityEvent) -> Bool {
    guard !failsWrites else { return false }
    sequence += 1
    history.append(MovieFolderActivityEntry(id: UUID(), sequence: sequence, occurredAt: Date(), event: event))
    if history.count > 500 { history.removeFirst(history.count - 500) }

    return true
  }

  func entries() async throws -> [MovieFolderActivityEntry] {
    readCount += 1
    if failsReads { throw Failure.unavailable }
    let snapshot = history
    if shouldHoldRead {
      shouldHoldRead = false
      await withCheckedContinuation { heldRead = $0 }
    }

    return snapshot
  }

  func clear() throws {
    if failsClear { throw Failure.unavailable }
    history = []
  }
}

/// Verifies opening loads persisted history, Clear scope, and independent failures.
@MainActor
struct ActivityLogViewModelTests {
  /// Verifies opening the log reloads committed service history.
  @Test func openingAndReopeningLoadsActualServiceHistory() async {
    let service = ActivityServiceFake()
    await service.record(MovieFolderActivityEvent(action: .applicationOpened, status: .succeeded))
    let log = ActivityLogViewModel(service: service)
    #expect(log.statusText.contains("Loading"))
    await log.reload()
    #expect(log.entries.count == 1)
    await service.record(MovieFolderActivityEvent(action: .posterRefresh, status: .succeeded))
    await log.reload()
    #expect(log.entries.count == 2)
  }

  /// Preserves displayed history and reports a distinct clear failure.
  @Test func clearFailureKeepsEntriesAndShowsDistinctMessage() async {
    let service = ActivityServiceFake()
    let log = ActivityLogViewModel(service: service)
    await log.record(MovieFolderActivityEvent(action: .applicationOpened, status: .succeeded))
    await service.setFailures(clear: true)
    await log.clear()
    #expect(log.entries.count == 1)
    #expect(log.hasClearFailure)
    #expect(!log.hasLoadFailure)
    #expect(log.statusText.contains("Could not clear"))
  }

  /// Verifies recording failures and history-loading failures have independent presentation state.
  @Test func failedWritesAndLoadsRemainSeparate() async {
    let service = ActivityServiceFake()
    let log = ActivityLogViewModel(service: service)
    await service.setFailures(write: true)
    await log.record(MovieFolderActivityEvent(action: .credentialSaved, status: .succeeded))
    #expect(log.hasObservedWriteFailure)
    #expect(!log.hasLoadFailure)
    await service.setFailures(read: true)
    await log.reload()
    #expect(log.hasLoadFailure)
    #expect(!log.hasClearFailure)
  }

  /// Prevents an older read from restoring cleared history and coalesces reload notifications.
  @Test func clearFencesAnOlderCapturedReadAndCoalescesHints() async {
    let service = ActivityServiceFake()
    await service.record(MovieFolderActivityEvent(action: .applicationOpened, status: .succeeded))
    let log = ActivityLogViewModel(service: service)
    await service.holdNextRead()
    let reload = Task { await log.reload() }
    while !(await service.isReadHeld) { await Task.yield() }
    for _ in 0..<20 { await log.reload() }
    await log.clear()
    await service.releaseRead()
    await reload.value
    #expect(log.entries.isEmpty)
    #expect(!log.hasLoadFailure)
    #expect(await service.readCount == 2)
  }

  /// Rejects stale reads after failed clearing while preserving its failure message.
  @Test func failedClearFencesCapturedReadAndReloadsHistoryWithoutLosingFailure() async {
    let service = ActivityServiceFake()
    await service.record(MovieFolderActivityEvent(action: .applicationOpened, status: .succeeded))
    let log = ActivityLogViewModel(service: service)
    await log.reload()
    await service.holdNextRead()
    let reload = Task { await log.reload() }
    while !(await service.isReadHeld) { await Task.yield() }
    await service.record(MovieFolderActivityEvent(action: .posterRemoval, status: .succeeded))
    await service.setFailures(clear: true)
    await log.clear()
    await service.releaseRead()
    await reload.value
    #expect(log.entries.map(\.sequence) == [1, 2])
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
    #expect(await first.record(MovieFolderActivityEvent(action: .applicationOpened, status: .succeeded)))
    let log = ActivityLogViewModel(service: first)
    await log.reload()
    #expect(log.entries.count == 1)
    let otherProcess = MovieFolderActivityRecorder(directory: directory, notifier: IgnoredActivityChangeNotifier())
    #expect(await otherProcess.record(MovieFolderActivityEvent(action: .automaticProcessing, status: .partial)))
    #expect(log.entries.count == 1)
    await log.reload()
    #expect(log.entries.map(\.sequence) == [1, 2])
    #expect(log.entries.last?.event.status == .partial)
    #expect(!log.hasLoadFailure)
  }

  /// Verifies manual-action events retain safe failure and correlation data without user text.
  @Test func actualManualProducerRetainsFailureAndCorrelationWithoutUserText() async throws {
    let activity = ActivityServiceFake()
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
    #expect(events.first?.activityGroupID != .none)
    #expect(events.first?.activityGroupID == events.last?.activityGroupID)
    #expect(events.allSatisfy { $0.collectionID == rootID })
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
