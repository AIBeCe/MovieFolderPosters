import Common
import Foundation

/// Prepares the exact bytes shown in an export preview.
nonisolated protocol LocalDataExportPreparing: Sendable {
  func prepare(
    selection: LocalDataExportOptions, evidence: LocalDataExportInputs,
    readiness: InstallationReadinessReport?, storage: ApplicationLocalStorageReport?
  ) async throws -> Data
}

/// Projects selected history into the existing allowlisted export document.
nonisolated struct LocalDataExportPreparer: LocalDataExportPreparing {
  @concurrent func prepare(
    selection: LocalDataExportOptions, evidence: LocalDataExportInputs,
    readiness: InstallationReadinessReport?, storage: ApplicationLocalStorageReport?
  ) async throws -> Data {
    try Task.checkCancellation()
    let activity = selection.shownActivity(evidence.activity ?? [])
      .filter { selection.selectedActivity.contains($0.id) }
    let network = selection.shownNetwork(evidence.network ?? [])
      .filter { selection.selectedNetwork.contains($0.id) }
    let document = LocalDataExportContents(
      activity: activity, network: network, readiness: readiness, storage: storage,
      start: selection.start, end: selection.end,
      activityAvailable: evidence.activity != nil, networkAvailable: evidence.network != nil)

    try Task.checkCancellation()
    let bytes = try document.encode()
    try Task.checkCancellation()

    return bytes
  }
}
