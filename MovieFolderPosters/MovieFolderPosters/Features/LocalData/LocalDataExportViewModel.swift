import Foundation
import MovieFolderCommon

/// Finite local data export selection and immutable preview state; all writes require current retained evidence.
@MainActor
final class LocalDataExportViewModel {
  /// Narrow source boundary retained through dismissal.
  private let service: any LocalDataExportServicing
  /// Current user choices; replacing choices invalidates the exact preview.
  var selection = LocalDataExportSelection() {
    didSet {
      generation &+= 1
      preview = .none
    }
  }
  /// Most recently captured retained evidence, independent of filters.
  private(set) var evidence: LocalDataExportSources?
  /// Exact encoded bytes displayed and later saved.
  private(set) var preview: Data?
  /// Readiness captured by the route that opened this flow.
  private let readiness: InstallationReadinessReport?
  /// Generation fences late reads and sheet closure.
  private var generation = UInt64.zero
  /// Whether the owner has ended this finite flow.
  private var isClosed = false

  /// Creates one nonpersistent local data export session.
  /// - Parameters:
  ///   - service: Read-only sources retained for this session.
  ///   - readiness: Fixed readiness evidence supplied by the opening route.
  init(service: any LocalDataExportServicing, readiness: InstallationReadinessReport?) {
    self.service = service
    self.readiness = readiness
  }

  /// Refreshes retained evidence, removing hidden selections and invalidating old previews.
  func reload() async {
    generation &+= 1
    let current = generation
    preview = .none
    let loaded = await service.load()

    guard !Task.isCancelled, !isClosed, current == generation else { return }

    evidence = loaded
    selection.reconcile(activity: loaded.activity ?? [], network: loaded.network ?? [])
  }

  /// Captures an exact allowlisted preview after checking selection and privacy availability.
  /// - Throws: `LocalDataExportError.invalidRange` when the flow, range, or loaded privacy evidence is unavailable;
  ///   `.stale` after cancellation or intervening changes; encoding or size-limit errors from the document.
  func preparePreview() async throws {
    guard !isClosed, selection.hasValidRange, let evidence, evidence.privacy != .none else {
      throw LocalDataExportError.invalidRange
    }

    generation &+= 1
    let current = generation
    let choices = selection
    let report: LocalStorageReport? = choices.includesStorage ? await service.storage() : .none

    guard !Task.isCancelled, !isClosed, current == generation else { throw LocalDataExportError.stale }

    preview = try LocalDataExportDocument(
      activity: choices.shownActivity(evidence.activity ?? []).filter { choices.selectedActivity.contains($0.id) },
      network: choices.shownNetwork(evidence.network ?? []).filter { choices.selectedNetwork.contains($0.id) },
      readiness: choices.includesReadiness ? readiness : .none, storage: report, start: choices.start, end: choices.end,
      activityAvailable: evidence.activity != nil, networkAvailable: evidence.network != nil
    ).encode()
  }

  /// Rechecks after destination selection; new entries are never silently included.
  /// - Returns: The exact previously displayed preview bytes.
  /// - Throws: `LocalDataExportError.stale` if no current preview exists, the flow closes or changes, or selected
  ///   evidence, source availability, or privacy no longer agrees.
  func bytesForSaving() async throws -> Data {
    guard !isClosed, let frozen = preview, let original = evidence else { throw LocalDataExportError.stale }

    let currentGeneration = generation
    let latest = await service.load()

    guard !isClosed, currentGeneration == generation, preview == frozen,
      original.privacy != .none, latest.privacy == original.privacy,
      retainedActivityUnchanged(original.activity, latest.activity),
      retainedNetworkUnchanged(original.network, latest.network)
    else {
      preview = .none
      throw LocalDataExportError.stale
    }

    return frozen
  }

  /// Invalidates reads and previews when the owning sheet or parent closes.
  func close() {
    isClosed = true
    generation &+= 1
    preview = .none
  }

  /// Checks selected identities and payloads without allowing cleared evidence to reappear.
  /// - Parameters:
  ///   - original: Source evidence used to prepare the preview, or `.none` if unavailable.
  ///   - latest: Current source evidence captured before saving.
  /// - Returns: Whether source availability agrees and each selected entry retains its sequence, occurrence time,
  ///   and typed event.
  private func retainedActivityUnchanged(
    _ original: [MovieFolderActivityLogEntry]?,
    _ latest: [MovieFolderActivityLogEntry]?
  ) -> Bool {
    if original == nil { return latest == nil }

    guard let latest else { return false }

    return selection.selectedActivity.allSatisfy { id in
      guard let before = original?.first(where: { $0.id == id }),
        let after = latest.first(where: { $0.id == id })
      else { return false }

      return before.sequence == after.sequence && before.occurredAt == after.occurredAt && before.event == after.event
    }
  }

  /// Compares selected HTTP entries independently; no operation correlation is inferred.
  /// - Parameters:
  ///   - original: HTTP evidence used to prepare the preview, or `.none` if unavailable.
  ///   - latest: Current HTTP evidence captured before saving.
  /// - Returns: Whether source availability agrees and each selected entry retains its sequence, occurrence time,
  ///   and typed event.
  private func retainedNetworkUnchanged(
    _ original: [MovieFolderNetworkHistoryEntry]?,
    _ latest: [MovieFolderNetworkHistoryEntry]?
  ) -> Bool {
    if original == nil { return latest == nil }

    guard let latest else { return false }

    return selection.selectedNetwork.allSatisfy { id in
      guard let before = original?.first(where: { $0.id == id }),
        let after = latest.first(where: { $0.id == id })
      else { return false }

      return before.sequence == after.sequence && before.occurredAt == after.occurredAt && before.event == after.event
    }
  }
}
