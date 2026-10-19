import Foundation
import MovieFolderCommon

/// Receives main-actor presentation updates from the retained history model.
@MainActor
protocol ActivityLogViewModelDelegate: AnyObject {
  /// Reports history, loading, or failure-state changes.
  func activityLogViewModelDidChange(_ log: ActivityLogViewModel)
}

/// Presents persisted activity, coalescing invalidations and fencing reads across Clear.
@MainActor
final class ActivityLogViewModel {
  /// Committed entries in retained sequence order.
  private(set) var entries: [MovieFolderActivityEntry] = []
  /// Whether a history read is outstanding.
  private(set) var isLoading = false
  /// Whether a history clear is outstanding.
  private(set) var isClearing = false
  /// Whether any persisted history has been loaded.
  private var hasLoaded = false
  /// Safe load failure shown independently of product outcomes.
  private(set) var hasLoadFailure = false
  /// Safe clear failure shown independently of product outcomes.
  private(set) var hasClearFailure = false
  /// Safe write failure shown independently of product outcomes.
  private(set) var hasObservedWriteFailure = false
  /// Required strongly retained storage service.
  private let service: any MovieFolderActivityServicing
  /// Monotonically increasing fence invalidated by Clear.
  private var generation = UInt64.zero
  /// Records a hint arriving while a read or Clear is already active.
  private var reloadRequested = false
  /// Weak UI observer; never responsible for storage or authorization.
  weak var delegate: (any ActivityLogViewModelDelegate)?

  /// Whether clearing persisted history is currently appropriate, including recovery from failed reads.
  var canClear: Bool { !isClearing && (!entries.isEmpty || hasLoadFailure) }

  /// Accessible fixed presentation text for independent history states.
  var statusText: String {
    var messages: [String] = []
    if isClearing {
      messages.append("Clearing activity history…")
    } else if isLoading || !hasLoaded {
      messages.append("Loading activity history…")
    } else if entries.isEmpty && !hasLoadFailure {
      messages.append("No retained activity.")
    }
    if hasLoadFailure { messages.append("Could not load activity history. Reopen Log to retry.") }
    if hasClearFailure { messages.append("Could not clear activity history. The previous history is retained.") }
    if hasObservedWriteFailure {
      messages.append("Some activity could not be saved. Product operation results are unchanged.")
    }

    return messages.joined(separator: " ")
  }

  /// Creates presentation state backed by a real or explicitly injected test service.
  init(service: any MovieFolderActivityServicing) { self.service = service }

  /// Requests an asynchronous coalesced reload, including when the window is reopened.
  func requestReload() { Task { await reload() } }

  /// Reads committed storage off the main actor through the Sendable service.
  func reload() async {
    reloadRequested = true
    guard !isLoading, !isClearing else { return }
    isLoading = true
    publish()
    repeat {
      reloadRequested = false
      let expectedGeneration = generation
      let observedWriteFailure = await service.hasObservedWriteFailure
      hasObservedWriteFailure = hasObservedWriteFailure || observedWriteFailure
      do {
        let loaded = try await service.entries()
        if generation == expectedGeneration && !isClearing {
          entries = loaded
          hasLoaded = true
          hasLoadFailure = false
        }
      } catch {
        if generation == expectedGeneration && !isClearing {
          hasLoaded = true
          hasLoadFailure = true
        }
      }
    } while reloadRequested && !isClearing
    isLoading = false
    publish()
  }

  /// Records typed activity without altering the product operation's outcome on failure.
  func record(_ event: MovieFolderActivityEvent) async {
    if !(await service.record(event)) { hasObservedWriteFailure = true }
    await reload()
  }

  /// Reports an independently attempted producer write and refreshes committed history.
  func producerDidRecord(saved: Bool) {
    if !saved { hasObservedWriteFailure = true }
    requestReload()
  }

  /// Clears only persisted activity and prevents an older in-flight read from restoring cleared entries.
  func clear() async {
    guard !isClearing else { return }
    generation &+= 1
    isClearing = true
    hasClearFailure = false
    publish()
    do {
      try await service.clear()
      entries = []
      hasLoaded = true
      hasLoadFailure = false
    } catch {
      hasClearFailure = true
    }
    isClearing = false
    await reload()
    publish()
  }

  /// Publishes presentation changes without exposing event payloads through notifications.
  private func publish() { delegate?.activityLogViewModelDidChange(self) }
}
