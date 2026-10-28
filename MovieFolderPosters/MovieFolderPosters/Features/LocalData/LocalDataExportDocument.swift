import Foundation
import MovieFolderCommon
import Network

/// Allowlisted product evidence; rich events are never serialized.
nonisolated struct LocalDataExportActivityEntry: Encodable {
  /// Finite occurrence time and fixed product vocabulary.
  let occurredAt: Date
  /// Closed product action vocabulary.
  let action: MovieFolderActivityLogEvent.Action
  /// Closed observed product result vocabulary.
  let status: MovieFolderActivityLogEvent.Status
  /// Optional terminal folder result without identifying context.
  let folderResult: MovieFolderActivityLogEvent.FolderResult?
  /// Optional fixed assessment of the observed folder result.
  let reason: FolderProcessingReason?
  /// Optional typed failure category, excluding raw errors.
  let failureReason: FolderProcessingFailureReason?
  /// Optional typed stage at which the failure occurred.
  let failureStage: FolderProcessingStage?
  /// Explicit numeric counters, excluding retry times and all contextual identifiers.
  let processingCounters: [String: Int]?

  /// Projects only fixed typed fields and explicit numeric counters.
  /// - Parameter entry: Retained event projected to allowlisted values.
  init(_ entry: MovieFolderActivityLogEntry) {
    occurredAt = entry.occurredAt
    let event = entry.event
    action = event.action
    status = event.status
    folderResult = event.folderResult
    reason = event.reason
    failureReason = event.failure?.reason
    failureStage = event.failure?.stage
    processingCounters = event.processingSummary.map { summary in
      [
        "examined": summary.examined, "excluded": summary.excluded, "assigned": summary.assigned,
        "restyled": summary.restyled, "unresolved": summary.unresolved,
        "transientFailures": summary.transientFailures, "skippedExistingIcons": summary.skippedExistingIcons,
        "skippedPreviouslyProcessed": summary.skippedPreviouslyProcessed,
        "skippedRetryWindow": summary.skippedRetryWindow
      ]
    }
  }
}

/// Allowlisted terminal HTTP evidence without linkage or request details.
nonisolated struct LocalDataExportNetworkEntry: Encodable {
  /// Finite terminal timestamp.
  let occurredAt: Date
  /// Closed request-purpose vocabulary.
  let purpose: TMDbRequestPurpose
  /// Typed terminal HTTP evidence, distinct from product success.
  let result: TMDbRequestResult
}

/// Versioned bounded JSON document; encoded bytes are frozen for exact preview and save.
nonisolated struct LocalDataExportDocument: Encodable {
  /// Current format version.
  let version = 1
  /// Time this document was constructed for preview.
  let capturedAt = Date()
  /// Beginning of the selected occurrence interval.
  let start: Date
  /// End of the selected occurrence interval.
  let end: Date
  /// Source availability is distinct from an empty selection.
  let activityAvailable: Bool
  /// Whether retained HTTP history could be read.
  let networkAvailable: Bool
  /// Independent fixed readiness statuses and metadata-only category report.
  let readiness: String?
  /// Optional metadata-only app storage evidence.
  let storage: LocalStorageReport?
  /// Selected evidence in each source's retained commit order.
  let activity: [LocalDataExportActivityEntry]
  /// Selected terminal HTTP entries in their retained commit order.
  let network: [LocalDataExportNetworkEntry]

  /// Projects source entries immediately, retaining no original records in the document.
  /// - Parameters:
  ///   - activity: Selected Activity entries in source order.
  ///   - network: Selected HTTP entries in source order.
  ///   - readiness: Optional fixed readiness statuses.
  ///   - storage: Optional metadata-only storage estimate.
  ///   - start: Beginning of the selected occurrence interval.
  ///   - end: End of the selected occurrence interval.
  ///   - activityAvailable: Whether Activity history was readable.
  ///   - networkAvailable: Whether HTTP history was readable.
  init(
    activity: [MovieFolderActivityLogEntry], network: [MovieFolderNetworkHistoryEntry],
    readiness: InstallationReadinessReport?, storage: LocalStorageReport?, start: Date, end: Date,
    activityAvailable: Bool, networkAvailable: Bool
  ) {
    self.start = start
    self.end = end
    self.activityAvailable = activityAvailable
    self.networkAvailable = networkAvailable
    self.readiness = readiness.map { InstallationDiagnosticsExport.installationCheckSummary(report: $0) }
    self.storage = storage
    self.activity = activity.map(LocalDataExportActivityEntry.init)
    self.network = network.map {
      LocalDataExportNetworkEntry(
        occurredAt: $0.occurredAt,
        purpose: $0.event.purpose, result: $0.event.result)
    }
  }

  /// Encodes the exact preview bytes, failing visibly instead of truncating evidence.
  /// - Returns: Versioned UTF-8 JSON bytes within the document size limit.
  /// - Throws: When encoding fails or the encoded document exceeds 2 MiB.
  func encode() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    let bytes = try encoder.encode(self)

    guard bytes.count <= 2 * 1024 * 1024 else { throw LocalDataExportError.tooLarge }

    return bytes
  }
}

/// Safe failure vocabulary presented without underlying errors.
nonisolated enum LocalDataExportError: Error { case tooLarge, stale, unavailable, invalidRange }
