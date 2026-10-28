import Foundation
import MovieFolderCommon

/// Explicit finite selection; retained order is never replaced with occurrence-time sorting.
nonisolated struct LocalDataExportSelection {
  /// Beginning and end of the inclusive occurrence filter.
  var start: Date
  /// End of the selected occurrence interval.
  var end: Date
  /// Whether each history source participates in selection.
  var activityEnabled = true
  /// Whether terminal HTTP entries participate in selection.
  var networkEnabled = false
  /// Opaque identities are retained in memory only and never encoded.
  var selectedActivity = Set<UUID>()
  /// Explicit selected HTTP identities, retained only in memory.
  var selectedNetwork = Set<UUID>()
  /// Explicit inclusion choices for independent evidence.
  var includesReadiness = true
  /// Whether the metadata-only storage report is included.
  var includesStorage = true
  /// Whether filtering and preview can proceed safely.
  var hasValidRange: Bool { start.timeIntervalSince1970.isFinite && end.timeIntervalSince1970.isFinite && start <= end }

  /// Defaults to the preceding 24 hours with no selected entries.
  init(now: Date = Date()) {
    start = now.addingTimeInterval(-86400)
    end = now
  }
  /// Filters without reordering the source's commit order.
  func shownActivity(_ entries: [MovieFolderActivityLogEntry]) -> [MovieFolderActivityLogEntry] {
    activityEnabled && hasValidRange ? entries.filter { contains($0.occurredAt) } : []
  }
  /// Filters HTTP evidence independently of product actions.
  func shownNetwork(_ entries: [MovieFolderNetworkHistoryEntry]) -> [MovieFolderNetworkHistoryEntry] {
    networkEnabled && hasValidRange ? entries.filter { contains($0.occurredAt) } : []
  }
  /// Removes every selection hidden by changed controls or cleared retained history.
  mutating func reconcile(activity: [MovieFolderActivityLogEntry], network: [MovieFolderNetworkHistoryEntry]) {
    selectedActivity.formIntersection(shownActivity(activity).map(\.id))
    selectedNetwork.formIntersection(shownNetwork(network).map(\.id))
  }
  /// Excludes malformed timestamps even if the range is otherwise valid.
  private func contains(_ date: Date) -> Bool {
    date.timeIntervalSince1970.isFinite && date >= start && date <= end
  }
}
