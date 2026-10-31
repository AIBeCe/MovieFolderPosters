import Foundation
import Testing

@testable import MovieFolderCommon

/// Regression coverage for serialized visits, cancellation draining, and registration races.
struct DirectoryObservationSchedulerTests {
  /// Verifies retains Delegate And Supplies Scheduler For Loading.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func retainsDelegateAndSuppliesSchedulerForLoading() async throws {
    let stream = AsyncStream<SchedulerEvent>.makeStream()
    let root = URL(fileURLWithPath: "/RetainedRoot")
    var probe: SchedulerProbe? = SchedulerProbe(roots: [root], events: stream.continuation)
    weak let weakProbe = probe
    let scheduler = FinderDirectoryObservationScheduler(delegate: try #require(probe))
    probe = .none

    #expect(weakProbe != nil)
    await scheduler.reload()
    #expect(await weakProbe?.loadCount == 1)
    #expect(await weakProbe?.loadingScheduler === scheduler)
    await scheduler.cancel()
    stream.continuation.finish()
  }

  /// Verifies reload Drains Cancelled Work Before Accepting New Configuration.
  @Test func reloadDrainsCancelledWorkBeforeAcceptingNewConfiguration() async {
    let stream = AsyncStream<SchedulerEvent>.makeStream()
    let first = URL(fileURLWithPath: "/First")
    let probe = SchedulerProbe(roots: [first], events: stream.continuation)
    let scheduler = FinderDirectoryObservationScheduler(delegate: probe)
    await scheduler.reload()
    var events = stream.stream.makeAsyncIterator()
    #expect(await events.next() == .loaded)
    await scheduler.begin(first)
    #expect(await events.next() == .started(first))
    await probe.setRoots([])
    let reload = Task { await scheduler.reload() }
    #expect(await events.next() == .cancelled)
    await scheduler.begin(first)
    await scheduler.reload()
    #expect(await probe.loadCount == 1)
    #expect(await probe.processed == [first])
    await probe.release()
    await reload.value
    #expect(await probe.loadCount == 3)
    await scheduler.begin(first)
    #expect(await probe.processed == [first])
    await scheduler.cancel()
    stream.continuation.finish()
  }

  /// Verifies bounds Work And Drops Directories Whose Observation Ended.
  @Test func boundsWorkAndDropsDirectoriesWhoseObservationEnded() async {
    let stream = AsyncStream<SchedulerEvent>.makeStream()
    let first = URL(fileURLWithPath: "/First")
    let second = URL(fileURLWithPath: "/Second")
    let probe = SchedulerProbe(roots: [first, second], events: stream.continuation)
    let scheduler = FinderDirectoryObservationScheduler(delegate: probe)
    await scheduler.reload()
    var events = stream.stream.makeAsyncIterator()
    #expect(await events.next() == .loaded)
    await scheduler.begin(first)
    #expect(await events.next() == .started(first))
    await scheduler.begin(second)
    await scheduler.end(second)
    #expect(await probe.processed == [first])
    await scheduler.cancel()
    #expect(await events.next() == .cancelled)
    await probe.release()
    #expect(await probe.processed == [first])
    stream.continuation.finish()
  }
  /// Verifies retains First Observation Arriving Before Registration Returns.
  @Test func retainsFirstObservationArrivingBeforeRegistrationReturns() async {
    let stream = AsyncStream<SchedulerEvent>.makeStream()
    let directory = URL(fileURLWithPath: "/NewRoot")
    let probe = SchedulerProbe(roots: [directory], events: stream.continuation)
    await probe.pauseNextLoad()
    let scheduler = FinderDirectoryObservationScheduler(delegate: probe)
    var events = stream.stream.makeAsyncIterator()
    let reload = Task { await scheduler.reload() }
    #expect(await events.next() == .loading)
    await scheduler.begin(directory)
    await probe.releaseLoad()
    await reload.value
    #expect(await events.next() == .loaded)
    #expect(await events.next() == .started(directory))
    await scheduler.cancel()
    #expect(await events.next() == .cancelled)
    await probe.release()
    stream.continuation.finish()
  }

  /// Verifies reopening During Cancellation Starts One Replacement After Drain.
  @Test func reopeningDuringCancellationStartsOneReplacementAfterDrain() async {
    let stream = AsyncStream<SchedulerEvent>.makeStream()
    let directory = URL(fileURLWithPath: "/Root")
    let probe = SchedulerProbe(roots: [directory], events: stream.continuation)
    let scheduler = FinderDirectoryObservationScheduler(delegate: probe)
    var events = stream.stream.makeAsyncIterator()
    await scheduler.reload()
    #expect(await events.next() == .loaded)
    await scheduler.begin(directory)
    #expect(await events.next() == .started(directory))
    await scheduler.end(directory)
    #expect(await events.next() == .cancelled)
    await scheduler.begin(directory)
    await scheduler.begin(directory)
    #expect(await probe.processed == [directory])
    await probe.release()
    #expect(await events.next() == .started(directory))
    #expect(await probe.processed == [directory, directory])
    await scheduler.cancel()
    #expect(await events.next() == .cancelled)
    await probe.release()
    stream.continuation.finish()
  }

  /// A change during processing must receive one follow-up visit, even after several notifications.
  @Test func changesDuringProcessingCoalesceIntoOneFollowUp() async {
    let stream = AsyncStream<SchedulerEvent>.makeStream()
    let root = URL(fileURLWithPath: "/ObservedRoot")
    let probe = SchedulerProbe(roots: [root], events: stream.continuation)
    let scheduler = FinderDirectoryObservationScheduler(delegate: probe)
    await scheduler.reload()
    var events = stream.stream.makeAsyncIterator()
    #expect(await events.next() == .loaded)
    await scheduler.begin(root)
    #expect(await events.next() == .started(root))

    await scheduler.directoryContentsChanged(root)
    await scheduler.directoryContentsChanged(root)
    await probe.release()
    #expect(await events.next() == .started(root))
    #expect(await probe.processed == [root, root])

    await scheduler.cancel()
    #expect(await events.next() == .cancelled)
    await probe.release()
    stream.continuation.finish()
  }

  /// A provider deadline resumes a still-observed collection once the gate has expired.
  @Test func providerDeadlineResumesObservedRoot() async throws {
    let stream = AsyncStream<SchedulerEvent>.makeStream()
    let root = URL(fileURLWithPath: "/ObservedRoot")
    let probe = SchedulerProbe(roots: [root], events: stream.continuation)
    let scheduler = FinderDirectoryObservationScheduler(delegate: probe)
    await scheduler.reload()
    var events = stream.stream.makeAsyncIterator()
    #expect(await events.next() == .loaded)
    await probe.setNextDeadline(Date().addingTimeInterval(0.5))
    await scheduler.begin(root)
    #expect(await events.next() == .started(root))
    await probe.release()
    #expect(try await waitForScheduledRetry(scheduler, root: root))

    try await Task.sleep(for: .milliseconds(650))
    #expect(await probe.processed == [root, root])
    await scheduler.cancel()
    await probe.release()
    stream.continuation.finish()
  }

  /// A deadline that expires before processing returns still resumes the deferred remainder.
  @Test func expiredProviderDeadlineQueuesOneImmediateContinuation() async throws {
    let stream = AsyncStream<SchedulerEvent>.makeStream()
    let root = URL(fileURLWithPath: "/ObservedRoot")
    let probe = SchedulerProbe(roots: [root], events: stream.continuation)
    let scheduler = FinderDirectoryObservationScheduler(delegate: probe)
    await scheduler.reload()
    var events = stream.stream.makeAsyncIterator()
    #expect(await events.next() == .loaded)
    await probe.setNextDeadline(Date().addingTimeInterval(-1))
    await scheduler.begin(root)
    #expect(await events.next() == .started(root))
    await probe.release()
    #expect(await events.next() == .started(root))
    #expect(await probe.processed == [root, root])

    await scheduler.cancel()
    #expect(await events.next() == .cancelled)
    await probe.release()
    stream.continuation.finish()
  }

  /// Closing a collection cancels its scheduled provider retry.
  @Test func endingObservationCancelsProviderRetry() async throws {
    let stream = AsyncStream<SchedulerEvent>.makeStream()
    let root = URL(fileURLWithPath: "/ObservedRoot")
    let probe = SchedulerProbe(roots: [root], events: stream.continuation)
    let scheduler = FinderDirectoryObservationScheduler(delegate: probe)
    await scheduler.reload()
    var events = stream.stream.makeAsyncIterator()
    #expect(await events.next() == .loaded)
    await probe.setNextDeadline(Date().addingTimeInterval(0.5))
    await scheduler.begin(root)
    #expect(await events.next() == .started(root))
    await probe.release()
    #expect(try await waitForScheduledRetry(scheduler, root: root))
    await scheduler.end(root)

    try await Task.sleep(for: .milliseconds(650))
    #expect(await probe.processed == [root])
    await scheduler.cancel()
    stream.continuation.finish()
  }

  /// A retry from an old observation cannot start work after the same root is reopened.
  @Test func reopeningDoesNotInheritCancelledProviderDeadline() async throws {
    let stream = AsyncStream<SchedulerEvent>.makeStream()
    let root = URL(fileURLWithPath: "/ObservedRoot")
    let probe = SchedulerProbe(roots: [root], events: stream.continuation)
    let scheduler = FinderDirectoryObservationScheduler(delegate: probe)
    await scheduler.reload()
    var events = stream.stream.makeAsyncIterator()
    #expect(await events.next() == .loaded)
    await probe.setNextDeadline(Date().addingTimeInterval(0.5))
    await scheduler.begin(root)
    #expect(await events.next() == .started(root))
    await probe.release()
    #expect(try await waitForScheduledRetry(scheduler, root: root))
    await scheduler.end(root)
    await scheduler.begin(root)
    #expect(await events.next() == .started(root))
    await probe.release()

    try await Task.sleep(for: .milliseconds(650))
    #expect(await probe.processed == [root, root])
    await scheduler.cancel()
    stream.continuation.finish()
  }

  /// A configuration reload removes the prior deadline and does not retry a removed root.
  @Test func reloadCancelsProviderRetryForRemovedRoot() async throws {
    let stream = AsyncStream<SchedulerEvent>.makeStream()
    let root = URL(fileURLWithPath: "/ObservedRoot")
    let probe = SchedulerProbe(roots: [root], events: stream.continuation)
    let scheduler = FinderDirectoryObservationScheduler(delegate: probe)
    await scheduler.reload()
    var events = stream.stream.makeAsyncIterator()
    #expect(await events.next() == .loaded)
    await probe.setNextDeadline(Date().addingTimeInterval(0.5))
    await scheduler.begin(root)
    #expect(await events.next() == .started(root))
    await probe.release()
    #expect(try await waitForScheduledRetry(scheduler, root: root))
    await probe.setRoots([])
    await scheduler.reload()

    try await Task.sleep(for: .milliseconds(650))
    #expect(await probe.processed == [root])
    await scheduler.cancel()
    stream.continuation.finish()
  }

  /// A real root-directory addition wakes an observed local collection.
  @Test func localDirectoryAdditionQueuesAnotherVisit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let stream = AsyncStream<SchedulerEvent>.makeStream()
    let probe = SchedulerProbe(roots: [root], events: stream.continuation)
    let scheduler = FinderDirectoryObservationScheduler(delegate: probe)
    await scheduler.reload()
    var events = stream.stream.makeAsyncIterator()
    #expect(await events.next() == .loaded)
    await scheduler.begin(root)
    #expect(await events.next() == .started(root))

    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("New Movie", isDirectory: true), withIntermediateDirectories: false)
    try await Task.sleep(for: .milliseconds(600))
    await probe.release()
    try await Task.sleep(for: .milliseconds(300))
    #expect(await probe.processed == [root, root])

    await scheduler.cancel()
    await probe.release()
    stream.continuation.finish()
  }

  /// Saving passive settings must not synthesize a visit for an idle observed root.
  @Test func passiveReloadDoesNotScheduleIdleObservedRoot() async throws {
    let stream = AsyncStream<SchedulerEvent>.makeStream()
    let root = URL(fileURLWithPath: "/PassiveIdle")
    let sentinel = URL(fileURLWithPath: "/PassiveIdleSentinel")
    let probe = SchedulerProbe(roots: [root, sentinel], events: stream.continuation)
    let scheduler = FinderDirectoryObservationScheduler(delegate: probe)
    var events = stream.stream.makeAsyncIterator()
    await scheduler.reload()
    #expect(await events.next() == .loaded)
    await probe.setNextDeadline(Date().addingTimeInterval(60))
    await scheduler.begin(root)
    #expect(await events.next() == .started(root))
    await probe.release()
    #expect(try await waitForScheduledRetry(scheduler, root: root))
    await scheduler.reload(scheduleObservedCollections: false)
    #expect(await events.next() == .loaded)
    await scheduler.begin(sentinel)
    #expect(await events.next() == .started(sentinel))
    #expect(await probe.processed == [root, sentinel])
    #expect(await probe.loadCount == 2)
    #expect(await scheduler.hasScheduledRetry(for: root))
    await scheduler.cancel()
    await probe.release()
    stream.continuation.finish()
  }

  /// Passive reload drains cancellation before loading settings, without replacing the cancelled visit.
  @Test func passiveReloadDrainsActiveWorkWithoutReplacement() async throws {
    let stream = AsyncStream<SchedulerEvent>.makeStream()
    let root = URL(fileURLWithPath: "/PassiveActive")
    let sentinel = URL(fileURLWithPath: "/PassiveActiveSentinel")
    let probe = SchedulerProbe(roots: [root, sentinel], events: stream.continuation)
    let scheduler = FinderDirectoryObservationScheduler(delegate: probe)
    var events = stream.stream.makeAsyncIterator()
    await scheduler.reload()
    #expect(await events.next() == .loaded)
    await scheduler.begin(root)
    #expect(await events.next() == .started(root))
    let reload = Task { await scheduler.reload(scheduleObservedCollections: false) }
    #expect(await events.next() == .cancelled)
    #expect(await probe.loadCount == 1)
    #expect(await probe.processed == [root])
    await probe.release()
    await reload.value
    #expect(await events.next() == .loaded)
    await scheduler.begin(sentinel)
    #expect(await events.next() == .started(sentinel))
    #expect(await probe.processed == [root, sentinel])
    #expect(await probe.loadCount == 2)
    await scheduler.cancel()
    await probe.release()
    stream.continuation.finish()
  }

  /// Existing queued visits, new observations, and real change events survive a passive settings reload.
  @Test(arguments: ["pending", "begin", "change"])
  func passiveReloadRetainsGenuineTriggers(trigger: String) async {
    let stream = AsyncStream<SchedulerEvent>.makeStream()
    let first = URL(fileURLWithPath: "/PassiveFirst")
    let second = URL(fileURLWithPath: "/PassiveSecond")
    let probe = SchedulerProbe(roots: [first, second], events: stream.continuation)
    let scheduler = FinderDirectoryObservationScheduler(delegate: probe)
    var events = stream.stream.makeAsyncIterator()
    await scheduler.reload()
    #expect(await events.next() == .loaded)
    await scheduler.begin(first)
    #expect(await events.next() == .started(first))
    if trigger == "pending" { await scheduler.begin(second) }
    let reload = Task { await scheduler.reload(scheduleObservedCollections: false) }
    #expect(await events.next() == .cancelled)
    if trigger == "begin" { await scheduler.begin(second) }
    if trigger == "change" { await scheduler.directoryContentsChanged(first) }
    await probe.release()
    await reload.value
    let expected = trigger == "change" ? first : second
    #expect(await events.next() == .loaded)
    #expect(await events.next() == .started(expected))
    #expect(await probe.processed == [first, expected])
    await scheduler.cancel()
    await probe.release()
    stream.continuation.finish()
  }

  /// An existing retry remains valid even when its deadline elapses while passive configuration loading is held.
  @Test func passiveReloadRetainsExistingRetryGeneration() async throws {
    let stream = AsyncStream<SchedulerEvent>.makeStream()
    let root = URL(fileURLWithPath: "/PassiveDeadline")
    let probe = SchedulerProbe(roots: [root], events: stream.continuation)
    let scheduler = FinderDirectoryObservationScheduler(delegate: probe)
    var events = stream.stream.makeAsyncIterator()
    await scheduler.reload()
    #expect(await events.next() == .loaded)
    await probe.setNextDeadline(Date().addingTimeInterval(0.3))
    await scheduler.begin(root)
    #expect(await events.next() == .started(root))
    await probe.release()
    #expect(try await waitForScheduledRetry(scheduler, root: root))
    await probe.pauseNextLoad()
    let reload = Task { await scheduler.reload(scheduleObservedCollections: false) }
    #expect(await events.next() == .loading)
    #expect(await scheduler.hasScheduledRetry(for: root))
    try await Task.sleep(for: .milliseconds(400))
    #expect(await probe.processed == [root])
    await probe.releaseLoad()
    await reload.value
    #expect(await events.next() == .loaded)
    #expect(await events.next() == .started(root))
    #expect(await probe.processed == [root, root])
    await scheduler.cancel()
    await probe.release()
    stream.continuation.finish()
  }

  /// An actual filesystem source remains live and retains its event while passive configuration loading is held.
  @Test func passiveReloadRetainsFilesystemEvent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let stream = AsyncStream<SchedulerEvent>.makeStream()
    let probe = SchedulerProbe(roots: [root], events: stream.continuation)
    let scheduler = FinderDirectoryObservationScheduler(delegate: probe)
    var events = stream.stream.makeAsyncIterator()
    await scheduler.reload()
    #expect(await events.next() == .loaded)
    await probe.setNextDeadline(Date().addingTimeInterval(10))
    await scheduler.begin(root)
    #expect(await events.next() == .started(root))
    await probe.release()
    #expect(try await waitForScheduledRetry(scheduler, root: root))
    await probe.pauseNextLoad()
    let reload = Task { await scheduler.reload(scheduleObservedCollections: false) }
    #expect(await events.next() == .loading)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("New Movie"),
      withIntermediateDirectories: false)
    try await Task.sleep(for: .milliseconds(400))
    #expect(await probe.processed == [root])
    await probe.releaseLoad()
    await reload.value
    #expect(await events.next() == .loaded)
    #expect(await events.next() == .started(root))
    #expect(await probe.processed == [root, root])
    await scheduler.cancel()
    await probe.release()
    stream.continuation.finish()
  }

  /// An ordinary reload wins during coalescing, including when later passive requests arrive before drain.
  @Test(arguments: [false, true])
  func normalReloadRemainsStickyAcrossPassiveRequests(startsNormally: Bool) async {
    let stream = AsyncStream<SchedulerEvent>.makeStream()
    let root = URL(fileURLWithPath: "/StickyReload")
    let probe = SchedulerProbe(roots: [root], events: stream.continuation)
    let scheduler = FinderDirectoryObservationScheduler(delegate: probe)
    var events = stream.stream.makeAsyncIterator()
    await scheduler.reload()
    #expect(await events.next() == .loaded)
    await scheduler.begin(root)
    #expect(await events.next() == .started(root))
    let reload = Task { await scheduler.reload(scheduleObservedCollections: startsNormally) }
    #expect(await events.next() == .cancelled)
    if !startsNormally { await scheduler.reload() }
    await scheduler.reload(scheduleObservedCollections: false)
    await scheduler.reload(scheduleObservedCollections: false)
    #expect(await probe.processed == [root])
    await probe.release()
    await reload.value
    #expect(await events.next() == .loaded)
    #expect(await events.next() == .loaded)
    #expect(await events.next() == .started(root))
    #expect(await probe.processed == [root, root])
    #expect(await probe.loadCount == 3)
    await scheduler.cancel()
    await probe.release()
    stream.continuation.finish()
  }

  /// Removed roots lose existing retries and queued visits, and cancelled work is not replaced.
  @Test func passiveReloadPrunesRemovedRootsScheduling() async throws {
    let stream = AsyncStream<SchedulerEvent>.makeStream()
    let first = URL(fileURLWithPath: "/RemovedDeadline")
    let second = URL(fileURLWithPath: "/RemovedActive")
    let third = URL(fileURLWithPath: "/RemovedPending")
    let probe = SchedulerProbe(roots: [first, second, third], events: stream.continuation)
    let scheduler = FinderDirectoryObservationScheduler(delegate: probe)
    var events = stream.stream.makeAsyncIterator()
    await scheduler.reload()
    #expect(await events.next() == .loaded)
    await probe.setNextDeadline(Date().addingTimeInterval(0.3))
    await scheduler.begin(first)
    #expect(await events.next() == .started(first))
    await probe.release()
    #expect(try await waitForScheduledRetry(scheduler, root: first))
    await scheduler.begin(second)
    #expect(await events.next() == .started(second))
    await scheduler.begin(third)
    await probe.setRoots([])
    let reload = Task { await scheduler.reload(scheduleObservedCollections: false) }
    #expect(await events.next() == .cancelled)
    await probe.release()
    await reload.value
    #expect(await !scheduler.hasScheduledRetry(for: first))
    await scheduler.begin(first)
    await scheduler.directoryContentsChanged(third)
    try await Task.sleep(for: .milliseconds(400))
    #expect(await probe.processed == [first, second])
    await scheduler.cancel()
    stream.continuation.finish()
  }

}

/// Waits until a completed visit has actually registered its retry before testing cancellation.
private func waitForScheduledRetry(_ scheduler: FinderDirectoryObservationScheduler, root: URL) async throws -> Bool {
  for _ in 0..<100 {
    if await scheduler.hasScheduledRetry(for: root) { return true }
    try await Task.sleep(for: .milliseconds(10))
  }

  return false
}

/// Observable load and processing boundaries used to coordinate scheduler tests.
private enum SchedulerEvent: Equatable, Sendable {
  case loading
  case loaded
  case started(URL)
  case cancelled
}

/// Controllable scheduler delegate exposing load and processing synchronization points.
private actor SchedulerProbe: DirectoryObservationSchedulerDelegate {
  /// The currently authorized roots, used for scheduling.
  private var roots: Set<URL>
  /// The stream continuation publishing scheduler synchronization boundaries.
  private let events: AsyncStream<SchedulerEvent>.Continuation
  /// The continuation holding an in-progress processing request.
  private var gate: CheckedContinuation<Void, Never>?
  /// The continuation holding a root-registration request.
  private var loadGate: CheckedContinuation<Void, Never>?
  /// Whether the next root load must wait for explicit release.
  private var shouldPauseLoad = false
  /// The deadline returned by the next completed processing request.
  private var nextDeadline: Date?
  /// A weak observation of the scheduler supplied to the delegate.
  private(set) weak var loadingScheduler: FinderDirectoryObservationScheduler?
  /// The number of completed or initiated root loads observed by the probe.
  private(set) var loadCount = Int.zero
  /// Root URLs passed to the processing delegate in call order.
  private(set) var processed: [URL] = []

  /// Creates the scheduler probe from the supplied dependencies and state.
  ///
  /// - Parameters:
  ///   - roots: The roots returned by the scheduler fixture.
  ///   - events: The stream continuation used to signal observable scheduler boundaries.
  init(roots: Set<URL>, events: AsyncStream<SchedulerEvent>.Continuation) {
    self.roots = roots
    self.events = events
  }

  /// Loads authorized roots while retaining the access needed by subsequent visits.
  ///
  /// - Parameter scheduler: The scheduler requesting configuration or root processing.
  /// - Returns: The currently authorized roots.
  func directoryObservationSchedulerLoadRoots(_ scheduler: FinderDirectoryObservationScheduler) async -> Set<URL> {
    loadingScheduler = scheduler
    loadCount += 1
    if shouldPauseLoad {
      shouldPauseLoad = false
      await withCheckedContinuation { continuation in
        loadGate = continuation
        events.yield(.loading)
      }
    }
    events.yield(.loaded)

    return roots
  }

  /// Makes the next configuration load wait for explicit release.
  func pauseNextLoad() { shouldPauseLoad = true }
  /// Resumes the blocked configuration load.
  func releaseLoad() {
    loadGate?.resume()
    loadGate = .none
  }

  /// Changes the roots returned by the next configuration reload.
  ///
  /// - Parameter roots: The roots returned by the scheduler fixture.
  func setRoots(_ roots: Set<URL>) { self.roots = roots }

  /// Sets the provider deadline to return from the next processing request.
  func setNextDeadline(_ deadline: Date?) { nextDeadline = deadline }

  /// Processes one observed root using the currently loaded configuration.
  ///
  /// - Parameters:
  ///   - scheduler: The scheduler requesting configuration or root processing.
  ///   - url: The deep link or observed root URL supplied by the caller.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func directoryObservationScheduler(
    _ scheduler: FinderDirectoryObservationScheduler, process url: URL
  ) async throws -> Date? {
    processed.append(url)
    let events = events
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        gate = continuation
        events.yield(.started(url))
      }
    } onCancel: { events.yield(.cancelled) }

    defer { nextDeadline = .none }

    return nextDeadline
  }

  /// Releases the held continuation or access so the test can observe completion.
  func release() {
    gate?.resume()
    gate = .none
  }
}
