import Foundation
import MovieFolderCommon

/// Receives main-actor presentation updates from the retained history model.
@MainActor
protocol LogViewModelDelegate: AnyObject {
  /// Reports history, loading, or failure-state changes.
  func logViewModelDidChange(_ log: LogViewModel)
}

/// Presents persisted activity, coalescing invalidations and fencing reads across Clear.
@MainActor
final class LogViewModel {
  /// Independently retained history sources.
  enum HistorySource: String, CaseIterable { case activity = "Activity", network = "Network" }
  /// Safe presentation fields; identifiers are used only for selection.
  struct HistoryEntryRow: Identifiable {
    /// Stable entry identity within the selected source.
    let id: UUID
    /// Displayed occurrence time.
    let occurredAt: Date
    /// Fixed privacy-safe message.
    let message: String
    /// Fixed action or request category.
    let category: String
    /// Evidence-based severity independent of category.
    let severity: String
    /// The exact time representation used by both table and copying.
    var timeText: String { occurredAt.formatted(.dateTime.year().month().day().hour().minute().second()) }
  }
  /// Selected history namespace.
  private(set) var historySource = HistorySource.activity
  /// Optional network history boundary; absent only in isolated activity fixtures.
  private let networkHistoryService: (any MovieFolderNetworkHistoryServicing)?
  /// Network rows loaded from their independent namespace.
  private var networkHistoryRows: [HistoryEntryRow] = []
  /// Current safe message/category search.
  private(set) var searchText = ""
  /// Exact optional category filter.
  private(set) var categoryFilter: String?
  /// Exact optional severity filter.
  private(set) var severityFilter: String?
  /// Stable selected identities, pruned whenever rows become hidden.
  private var selectedEntryIDs: Set<UUID> = []
  /// Persisted network recording state; reads and failed saves always reproject actual storage.
  private(set) var isNetworkHistoryRecordingEnabled = false
  /// Fences delayed preference reads against a newer explicit save.
  private var networkRecordingPreferenceGeneration = UInt64.zero
  /// Whether a network recording preference save is outstanding.
  private(set) var isSavingNetworkRecordingPreference = false
  /// Whether a recording-preference read failed.
  private var hasNetworkRecordingPreferenceReadFailure = false
  /// Whether an explicit recording-preference save failed.
  private var hasNetworkRecordingPreferenceSaveFailure = false
  /// Independent preference failure, excluding arbitrary errors.
  var hasNetworkRecordingPreferenceFailure: Bool {
    hasNetworkRecordingPreferenceReadFailure || hasNetworkRecordingPreferenceSaveFailure
  }
  /// All safe rows from the current source in retained order.
  func historyRows() -> [HistoryEntryRow] {
    historySource == .network ? networkHistoryRows : activityEntries.map {
      HistoryEntryRow(id: $0.id, occurredAt: $0.occurredAt, message: $0.event.text,
        category: $0.event.category, severity: $0.event.severity)
    }
  }
  /// Visible rows satisfying every local criterion.
  func filteredHistoryRows() -> [HistoryEntryRow] {
    historyRows().filter {
      (categoryFilter == .none || $0.category == categoryFilter)
        && (severityFilter == .none || $0.severity == severityFilter)
        && (searchText.isEmpty || ($0.message + " " + $0.category).localizedStandardContains(searchText))
    }
  }
  /// Available fixed categories in the selected namespace.
  func historyCategories() -> [String] { Array(Set(historyRows().map(\.category))).sorted() }
  /// Selected visible indexes suitable for table restoration.
  var selectedRows: IndexSet {
    IndexSet(filteredHistoryRows().indices.filter { selectedEntryIDs.contains(filteredHistoryRows()[$0].id) })
  }
  /// Copies exactly displayed fields, without persisted correlation identifiers.
  func textForSelectedHistoryRows() -> String {
    filteredHistoryRows().filter { selectedEntryIDs.contains($0.id) }.map {
      [$0.timeText, $0.message, $0.category, $0.severity].joined(separator: "\t")
    }.joined(separator: "\n")
  }
  /// Committed entries in retained sequence order.
  private(set) var activityEntries: [MovieFolderActivityLogEntry] = []
  /// Whether a history read is outstanding.
  private(set) var isLoading = false
  /// Whether a history clear is outstanding.
  private(set) var isClearing = false
  /// Whether any persisted history has been loaded.
  private var hasLoaded = false
  /// Retains each source's independent failures through source switches.
  private struct HistoryOperationFailures {
    /// A failed retained-history read.
    var hasLoadFailure = false
    /// A failed retained-history Clear.
    var hasClearFailure = false
    /// A failed optional history write.
    var hasWriteFailure = false
  }
  /// Independent operation evidence by namespace.
  private var historyOperationFailures: [HistorySource: HistoryOperationFailures] = [:]
  /// Safe load failure shown independently of product outcomes.
  private(set) var hasLoadFailure: Bool {
    get { historyOperationFailures[historySource]?.hasLoadFailure ?? false }
    set { historyOperationFailures[historySource, default: HistoryOperationFailures()].hasLoadFailure = newValue }
  }
  /// Safe clear failure shown independently of product outcomes.
  private(set) var hasClearFailure: Bool {
    get { historyOperationFailures[historySource]?.hasClearFailure ?? false }
    set { historyOperationFailures[historySource, default: HistoryOperationFailures()].hasClearFailure = newValue }
  }
  /// Safe write failure shown independently of product outcomes.
  private(set) var hasObservedWriteFailure: Bool {
    get { historyOperationFailures[historySource]?.hasWriteFailure ?? false }
    set { historyOperationFailures[historySource, default: HistoryOperationFailures()].hasWriteFailure = newValue }
  }
  /// Required strongly retained activity history service.
  private let activityHistoryService: any MovieFolderActivityServicing
  /// Monotonically increasing fence invalidated by Clear.
  private var historyReadGeneration = UInt64.zero
  /// Records a hint arriving while a read or Clear is already active.
  private var reloadRequested = false
  /// Weak UI observer; never responsible for storage or authorization.
  weak var delegate: (any LogViewModelDelegate)?

  /// Whether clearing persisted history is currently appropriate, including recovery from failed reads.
  var canClear: Bool { !isClearing && (!historyRows().isEmpty || hasLoadFailure) }

  /// Accessible fixed presentation text for independent history states.
  var statusText: String {
    let historyDescription = historySource.rawValue.lowercased() + " history"
    var messages: [String] = []
    if isClearing {
      messages.append("Clearing \(historyDescription)…")
    } else if isLoading || !hasLoaded {
      messages.append("Loading \(historyDescription)…")
    } else if historyRows().isEmpty && !hasLoadFailure {
      messages.append("No retained \(historySource.rawValue.lowercased()).")
    }
    if hasLoadFailure { messages.append("Could not load \(historyDescription). Reopen Log to retry.") }
    if hasClearFailure { messages.append("Could not clear \(historyDescription). The previous history is retained.") }
    if hasObservedWriteFailure {
      let failure = historySource == .activity
        ? "Some activity could not be saved." : "Some network history could not be saved."
      messages.append(failure + " Product operation results are unchanged.")
    }

    if hasNetworkRecordingPreferenceFailure {
      messages.append("Could not save or read network recording settings. Retry in Log.")
    }
    if !historyRows().isEmpty {
      messages.append("Showing \(filteredHistoryRows().count) of \(historyRows().count) retained entries.")
    }

    return messages.joined(separator: " ")
  }

  /// Creates presentation state backed by a real or explicitly injected test service.
  init(
    activityHistoryService: any MovieFolderActivityServicing,
    networkHistoryService: (any MovieFolderNetworkHistoryServicing)? = .none
  ) {
    self.activityHistoryService = activityHistoryService
    self.networkHistoryService = networkHistoryService
  }

  /// Changes source and fences any older in-flight read before requesting its replacement.
  func setSource(_ historySource: HistorySource) {
    guard self.historySource != historySource, !isClearing else { return }

    historyReadGeneration &+= 1
    self.historySource = historySource
    selectedEntryIDs = []
    hasLoaded = false
    categoryFilter = .none
    requestReload()
    publish()
  }

  /// Applies local criteria together and permanently prunes hidden identities.
  func setFilters(searchText: String, category: String?, severity: String?) {
    self.searchText = searchText
    categoryFilter = category
    severityFilter = severity
    pruneSelection()
    publish()
  }

  /// Replaces selection only with currently visible rows.
  func selectRows(_ indexes: IndexSet) {
    let visibleHistoryRows = filteredHistoryRows()
    selectedEntryIDs = Set(indexes.filter { visibleHistoryRows.indices.contains($0) }.map { visibleHistoryRows[$0].id })
    publish()
  }

  /// Saves recording independently of history retention and reverts presentation to actual saved state on failure.
  func setNetworkHistoryRecordingEnabled(_ enabled: Bool) async {
    guard let networkHistoryService, !isSavingNetworkRecordingPreference else { return }

    networkRecordingPreferenceGeneration &+= 1
    isSavingNetworkRecordingPreference = true
    hasNetworkRecordingPreferenceSaveFailure = false
    publish()
    do { try await networkHistoryService.setNetworkHistoryRecordingEnabled(enabled) }
    catch { hasNetworkRecordingPreferenceSaveFailure = true }
    do {
      isNetworkHistoryRecordingEnabled = try await networkHistoryService.isNetworkHistoryRecordingEnabled
      hasNetworkRecordingPreferenceReadFailure = false
    } catch { hasNetworkRecordingPreferenceReadFailure = true }
    isSavingNetworkRecordingPreference = false
    publish()
  }

  /// Requests an asynchronous coalesced reload, including when the window is reopened.
  func requestReload() { Task { await reload() } }

  /// Reads committed storage off the main actor through the Sendable activity history service.
  func reload() async {
    reloadRequested = true

    guard !isLoading, !isClearing else { return }

    isLoading = true
    publish()
    repeat {
      reloadRequested = false
      let expectedHistoryReadGeneration = historyReadGeneration
      let expectedHistorySource = historySource
      do {
        if let networkHistoryService, !isSavingNetworkRecordingPreference {
          let expectedNetworkRecordingPreferenceGeneration = networkRecordingPreferenceGeneration
          do {
            let enabled = try await networkHistoryService.isNetworkHistoryRecordingEnabled
            if networkRecordingPreferenceGeneration == expectedNetworkRecordingPreferenceGeneration {
              isNetworkHistoryRecordingEnabled = enabled
              hasNetworkRecordingPreferenceReadFailure = false
            }
          } catch {
            if networkRecordingPreferenceGeneration == expectedNetworkRecordingPreferenceGeneration {
              hasNetworkRecordingPreferenceReadFailure = true
            }
          }
        }
        let loadedActivityEntries: [MovieFolderActivityLogEntry]
        let loadedNetworkHistoryRows: [HistoryEntryRow]
        let observedWriteFailure: Bool
        if expectedHistorySource == .activity {
          observedWriteFailure = await activityHistoryService.hasObservedWriteFailure
          historyOperationFailures[expectedHistorySource, default: HistoryOperationFailures()].hasWriteFailure =
            (historyOperationFailures[expectedHistorySource]?.hasWriteFailure ?? false) || observedWriteFailure
          loadedActivityEntries = try await activityHistoryService.entries()
          loadedNetworkHistoryRows = []
        } else if let networkHistoryService {
          observedWriteFailure = await networkHistoryService.hasObservedWriteFailure
          historyOperationFailures[expectedHistorySource, default: HistoryOperationFailures()].hasWriteFailure =
            (historyOperationFailures[expectedHistorySource]?.hasWriteFailure ?? false) || observedWriteFailure
          loadedActivityEntries = []
          loadedNetworkHistoryRows = try await networkHistoryService.entries().map {
            HistoryEntryRow(id: $0.id, occurredAt: $0.occurredAt, message: $0.event.text,
              category: $0.event.category, severity: $0.event.severity)
          }
        } else {
          observedWriteFailure = false
          loadedActivityEntries = []
          loadedNetworkHistoryRows = []
        }
        if historyReadGeneration == expectedHistoryReadGeneration && !isClearing {
          if expectedHistorySource == .activity { activityEntries = loadedActivityEntries }
          else { networkHistoryRows = loadedNetworkHistoryRows }
          hasObservedWriteFailure = hasObservedWriteFailure || observedWriteFailure
          hasLoaded = true
          hasLoadFailure = false
          pruneSelection()
        }
      } catch {
        if historyReadGeneration == expectedHistoryReadGeneration && !isClearing {
          hasLoaded = true
          hasLoadFailure = true
        }
      }
    } while reloadRequested && !isClearing
    isLoading = false
    publish()
  }

  /// Records typed activity without altering the product operation's outcome on failure.
  func record(_ event: MovieFolderActivityLogEvent) async {
    if !(await activityHistoryService.record(event)) {
      historyOperationFailures[.activity, default: HistoryOperationFailures()].hasWriteFailure = true
    }
    await reload()
  }

  /// Reports an independently attempted producer write and refreshes committed history.
  func producerDidRecord(saved: Bool) {
    if !saved { historyOperationFailures[.activity, default: HistoryOperationFailures()].hasWriteFailure = true }
    requestReload()
  }

  /// Clears only persisted activity and prevents an older in-flight read from restoring cleared entries.
  func clear() async {
    guard !isClearing else { return }

    historyReadGeneration &+= 1
    isClearing = true
    hasClearFailure = false
    publish()
    do {
      if historySource == .activity { try await activityHistoryService.clear(); activityEntries = [] }
      else { try await networkHistoryService?.clear(); networkHistoryRows = [] }
      selectedEntryIDs = []
      hasLoaded = true
      hasLoadFailure = false
    } catch {
      hasClearFailure = true
    }
    isClearing = false
    await reload()
    publish()
  }

  /// Removes hidden selections before any later filter can reveal them again.
  private func pruneSelection() { selectedEntryIDs.formIntersection(Set(filteredHistoryRows().map(\.id))) }

  /// Publishes presentation changes without exposing event payloads through notifications.
  private func publish() { delegate?.logViewModelDidChange(self) }
}
