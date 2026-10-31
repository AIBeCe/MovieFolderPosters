import Darwin
import Dispatch
import Foundation
import OSLog

/// Loads authorized roots and processes visits through a strongly retained reference collaborator.
public protocol DirectoryObservationSchedulerDelegate: AnyObject, Sendable {
  /// Loads authorized roots while retaining the access needed by subsequent visits.
  ///
  /// - Parameter scheduler: The scheduler requesting configuration or root processing.
  /// - Returns: The currently authorized roots.
  func directoryObservationSchedulerLoadRoots(_ scheduler: FinderDirectoryObservationScheduler) async -> Set<URL>
  /// Processes one observed root using the currently loaded configuration.
  ///
  /// - Parameters:
  ///   - scheduler: The scheduler requesting configuration or root processing.
  ///   - url: The observed collection root URL.
  /// - Returns: The next eligible retry deadline while this root remains observed.
  /// - Throws: Cancellation or a failure reported by the configured processing collaborator.
  func directoryObservationScheduler(_ scheduler: FinderDirectoryObservationScheduler, process url: URL) async throws -> Date?
}

/// Serializes observed-root work and drains cancelled work before loading new configuration.
public actor FinderDirectoryObservationScheduler {
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
  /// Directory sources retained only while their configured roots remain observed.
  private var monitors: [URL: (source: any DispatchSourceFileSystemObject, identifier: UUID)] = [:]
  /// Short delays that combine bursts of directory changes into one visit per root.
  private var changeTasks: [URL: (task: Task<Void, Never>, identifier: UUID)] = [:]
  /// One-shot retry tasks for observed roots with deferred eligible work.
  private var retryTasks: [URL: (task: Task<Void, Never>, identifier: UUID)] = [:]
  /// Expired deadlines already given an immediate continuation, preventing a stale-result loop.
  private var resumedExpiredDeadlines: [URL: Date] = [:]
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
      stopAllMonitors()
      cancelDeferredTasks()
      resumedExpiredDeadlines = [:]
      activeTask?.cancel()
      await activeTask?.value
      activeTask = .none
      activeURL = .none
      pending = []
      guard !isStopped else { return }
      roots = await delegate.directoryObservationSchedulerLoadRoots(self)
      observed.formIntersection(roots)
      pending = Array(observed).sorted { $0.path < $1.path }
    } while reloadRequested && !isStopped
    for root in observed { startMonitoring(root) }
  }

  /// Queues a registered root when observation begins, coalescing duplicate visits.
  ///
  /// - Parameter url: The observed collection root URL.
  public func begin(_ url: URL) {
    let canonical = url.standardizedFileURL
    guard !isStopped, isReloading || roots.contains(canonical) else { return }
    observed.insert(canonical)
    if !isReloading { startMonitoring(canonical) }
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
    stopMonitoring(canonical)
    changeTasks.removeValue(forKey: canonical)?.task.cancel()
    retryTasks.removeValue(forKey: canonical)?.task.cancel()
    resumedExpiredDeadlines.removeValue(forKey: canonical)
    pending.removeAll { $0 == canonical }
    if activeURL == canonical { activeTask?.cancel() }
  }

  /// Stops future scheduling and cancels any active visit.
  public func cancel() {
    isStopped = true
    generation = UUID()
    activeTask?.cancel()
    stopAllMonitors()
    cancelDeferredTasks()
    resumedExpiredDeadlines = [:]
    pending = []
    observed = []
    roots = []
  }

  /// Queues one follow-up visit for a changed, still-observed root.
  ///
  /// - Parameter url: The configured root whose immediate children may have changed.
  func directoryContentsChanged(_ url: URL) {
    let canonical = url.standardizedFileURL
    guard !isStopped, roots.contains(canonical), observed.contains(canonical) else { return }
    if !pending.contains(canonical) { pending.append(canonical) }
    pump()
  }

  /// Reports whether a provider retry is scheduled, allowing focused lifecycle synchronization.
  ///
  /// - Parameter url: The configured observed root.
  /// - Returns: Whether an uncancelled retry is currently retained for that root.
  func hasScheduledRetry(for url: URL) -> Bool { retryTasks[url.standardizedFileURL] != nil }

  /// Starts a root-only directory source; its callback is advisory and never authorizes change.
  private func startMonitoring(_ url: URL) {
    guard monitors[url] == nil else { return }
    let descriptor = open(url.path, O_EVTONLY | O_CLOEXEC)
    guard descriptor >= 0 else {
      logger.notice("Could not monitor observed collection root")
      return
    }
    let identifier = UUID()
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .revoke],
      queue: DispatchQueue.global(qos: .utility))
    source.setEventHandler { [weak self] in
      Task { await self?.monitorChanged(url, identifier: identifier) }
    }
    source.setCancelHandler { _ = close(descriptor) }
    monitors[url] = (source, identifier)
    source.resume()
  }

  /// Accepts only events from the current source and combines an event burst before scanning.
  private func monitorChanged(_ url: URL, identifier: UUID) {
    guard monitors[url]?.identifier == identifier, changeTasks[url] == nil else { return }
    let changeIdentifier = UUID()
    let task = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
      await self?.deliverChange(url, monitorIdentifier: identifier, changeIdentifier: changeIdentifier)
    }
    changeTasks[url] = (task, changeIdentifier)
  }

  /// Delivers a coalesced directory event if its source still belongs to the observed root.
  private func deliverChange(_ url: URL, monitorIdentifier: UUID, changeIdentifier: UUID) {
    guard changeTasks[url]?.identifier == changeIdentifier else { return }
    changeTasks[url] = .none
    guard monitors[url]?.identifier == monitorIdentifier else { return }
    directoryContentsChanged(url)
  }

  /// Cancels a source and closes its descriptor through the source cancellation handler.
  private func stopMonitoring(_ url: URL) { monitors.removeValue(forKey: url)?.source.cancel() }

  /// Cancels all directory sources before an authorization reload or shutdown.
  private func stopAllMonitors() {
    for monitor in monitors.values { monitor.source.cancel() }
    monitors = [:]
  }

  /// Cancels pending event bursts and eligible retry deadlines.
  private func cancelDeferredTasks() {
    for entry in changeTasks.values { entry.task.cancel() }
    for entry in retryTasks.values { entry.task.cancel() }
    changeTasks = [:]
    retryTasks = [:]
  }

  /// Starts the next still-observed root only when no other task is active.
  private func pump() {
    guard !isReloading, !isStopped, activeTask == .none else { return }
    while let next = pending.first {
      pending.removeFirst()
      guard roots.contains(next), observed.contains(next) else { continue }
      retryTasks.removeValue(forKey: next)?.task.cancel()
      activeURL = next
      let identifier = generation
      activeTask = Task(priority: .utility) { [self] in
        var retryAt: Date?
        do {
          try Task.checkCancellation()
          retryAt = try await delegate.directoryObservationScheduler(self, process: next)
        } catch is CancellationError { logger.debug("Poster processing cancelled") } catch {
          logger.error("Poster processing failed")
        }
        completed(identifier, root: next, retryAt: retryAt)
      }
      break
    }
  }

  /// Accepts completion only from the active configuration generation and starts queued work.
  ///
  /// - Parameter identifier: The stable root or generation identifier involved in the operation.
  private func completed(_ identifier: UUID, root: URL, retryAt: Date?) {
    guard generation == identifier, activeURL == root else { return }
    activeTask = .none
    activeURL = .none
    if let retryAt, !pending.contains(root) { scheduleRetry(for: root, at: retryAt) }
    pump()
  }

  /// Schedules one continuation at a finite eligible deadline while the root remains observed.
  private func scheduleRetry(for root: URL, at deadline: Date) {
    guard observed.contains(root), roots.contains(root) else { return }
    let interval = deadline.timeIntervalSinceNow
    guard interval.isFinite else { return }
    if interval <= 0 {
      guard resumedExpiredDeadlines[root] != deadline else { return }
      resumedExpiredDeadlines[root] = deadline
      directoryContentsChanged(root)
      return
    }
    retryTasks.removeValue(forKey: root)?.task.cancel()
    let retryIdentifier = UUID()
    let currentGeneration = generation
    let task = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(interval)) } catch { return }
      await self?.retryElapsed(
        for: root, at: deadline, generation: currentGeneration, retryIdentifier: retryIdentifier)
    }
    retryTasks[root] = (task, retryIdentifier)
  }

  /// Rechecks wall-clock deadline and observation membership before retrying.
  private func retryElapsed(for root: URL, at deadline: Date, generation identifier: UUID, retryIdentifier: UUID) {
    guard generation == identifier, retryTasks[root]?.identifier == retryIdentifier,
      !isStopped, roots.contains(root), observed.contains(root) else { return }
    retryTasks[root] = .none
    if deadline > Date() {
      scheduleRetry(for: root, at: deadline)
    } else {
      resumedExpiredDeadlines[root] = deadline
      directoryContentsChanged(root)
    }
  }
}
