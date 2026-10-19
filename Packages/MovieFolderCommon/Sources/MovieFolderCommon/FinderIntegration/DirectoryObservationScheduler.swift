import Foundation
import OSLog

/// Loads authorized roots and processes visits through a strongly retained reference collaborator.
public protocol DirectoryObservationSchedulerDelegate: AnyObject, Sendable {
  /// Loads authorized roots while retaining the access needed by subsequent visits.
  ///
  /// - Parameter scheduler: The scheduler requesting configuration or root processing.
  /// - Returns: The currently authorized roots.
  func directoryObservationSchedulerLoadRoots(_ scheduler: DirectoryObservationScheduler) async -> Set<URL>
  /// Processes one observed root using the currently loaded configuration.
  ///
  /// - Parameters:
  ///   - scheduler: The scheduler requesting configuration or root processing.
  ///   - url: The observed collection root URL.
  /// - Throws: Cancellation or a failure reported by the configured processing collaborator.
  func directoryObservationScheduler(_ scheduler: DirectoryObservationScheduler, process url: URL) async throws
}

/// Serializes observed-root work and drains cancelled work before loading new configuration.
public actor DirectoryObservationScheduler {
  /// The strongly retained work collaborator, which can safely cross actor boundaries.
  private let delegate: any DirectoryObservationSchedulerDelegate
  /// The currently authorized roots, used for scheduling.
  private var roots: Set<URL> = []
  /// Registered roots that Finder is currently observing.
  private var observed: Set<URL> = []
  /// Observed roots awaiting their serialized processing turn.
  private var pending: [URL] = []
  /// The one processing task whose completion must drain before replacement work.
  private var activeTask: Task<Void, Never>?
  /// The root currently being processed, if any.
  private var activeURL: URL?
  /// A token rejecting completions from a superseded configuration generation.
  private var generation = UUID()
  /// Whether cancelled work is draining or new root configuration is being loaded.
  private var isReloading = false
  /// Whether another reload must run after the current reload completes.
  private var reloadRequested = false
  /// Whether all future observation and reload requests must be ignored.
  private var isStopped = false
  /// Privacy-preserving diagnostic events for this component.
  private let logger = Logger(subsystem: "dag.fikios.MovieFolderPosters", category: "ObservationScheduler")

  /// Retains the work delegate while starting with no registered or observed roots.
  ///
  /// - Parameter delegate: The strongly retained collaborator supplying serialized root work.
  public init(delegate: any DirectoryObservationSchedulerDelegate) {
    self.delegate = delegate
  }

  /// Cancels and drains old processing before loading and scheduling the current roots.
  public func reload() async {
    guard !isStopped else { return }
    reloadRequested = true
    guard !isReloading else { return }
    isReloading = true
    defer {
      isReloading = false
      pump()
    }
    repeat {
      reloadRequested = false
      generation = UUID()
      activeTask?.cancel()
      await activeTask?.value
      activeTask = nil
      activeURL = nil
      pending = []
      guard !isStopped else { return }
      roots = await delegate.directoryObservationSchedulerLoadRoots(self)
      observed.formIntersection(roots)
      pending = Array(observed).sorted { $0.path < $1.path }
    } while reloadRequested && !isStopped
  }

  /// Queues a registered root when observation begins, coalescing duplicate visits.
  ///
  /// - Parameter url: The observed collection root URL.
  public func begin(_ url: URL) {
    let canonical = url.standardizedFileURL
    guard !isStopped, isReloading || roots.contains(canonical) else { return }
    observed.insert(canonical)
    let needsReplacement = activeURL != canonical || activeTask?.isCancelled == true
    if needsReplacement && !pending.contains(canonical) { pending.append(canonical) }
    pump()
  }

  /// Drops queued visits and cancels active work when observation ends.
  ///
  /// - Parameter url: The observed collection root URL.
  public func end(_ url: URL) {
    let canonical = url.standardizedFileURL
    observed.remove(canonical)
    pending.removeAll { $0 == canonical }
    if activeURL == canonical { activeTask?.cancel() }
  }

  /// Stops future scheduling and cancels any active visit.
  public func cancel() {
    isStopped = true
    generation = UUID()
    activeTask?.cancel()
    pending = []
    observed = []
    roots = []
  }

  /// Starts the next still-observed root only when no other task is active.
  private func pump() {
    guard !isReloading, !isStopped, activeTask == nil else { return }
    while let next = pending.first {
      pending.removeFirst()
      guard roots.contains(next), observed.contains(next) else { continue }
      activeURL = next
      let identifier = generation
      activeTask = Task(priority: .utility) { [self] in
        do {
          try Task.checkCancellation()
          try await delegate.directoryObservationScheduler(self, process: next)
        } catch is CancellationError { logger.debug("Poster processing cancelled") } catch {
          logger.error("Poster processing failed")
        }
        completed(identifier)
      }
      break
    }
  }

  /// Accepts completion only from the active configuration generation and starts queued work.
  ///
  /// - Parameter identifier: The stable root or generation identifier involved in the operation.
  private func completed(_ identifier: UUID) {
    guard generation == identifier else { return }
    activeTask = nil
    activeURL = nil
    pump()
  }
}
