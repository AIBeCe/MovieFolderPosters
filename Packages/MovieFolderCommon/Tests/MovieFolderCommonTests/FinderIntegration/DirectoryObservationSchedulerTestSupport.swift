import Foundation
import Testing

@testable import MovieFolderCommon

/// Waits until a completed visit has actually registered its retry before testing cancellation.
func waitForScheduledRetry(_ scheduler: FinderDirectoryObservationScheduler, root: URL) async throws -> Bool {
  for _ in 0..<100 {
    if await scheduler.hasScheduledRetry(for: root) { return true }
    try await Task.sleep(for: .milliseconds(10))
  }

  return false
}

/// Observable load and processing boundaries used to coordinate scheduler tests.
enum SchedulerEvent: Equatable, Sendable {
  case loading
  case loaded
  case started(URL)
  case cancelled
}

/// Controllable scheduler delegate exposing load and processing synchronization points.
actor SchedulerProbe: DirectoryObservationSchedulerDelegate {
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
