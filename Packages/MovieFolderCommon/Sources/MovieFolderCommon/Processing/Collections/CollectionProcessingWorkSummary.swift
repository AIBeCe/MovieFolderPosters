import Foundation

/// Independent work counts supported by the saved immediate-child inventory.
nonisolated public struct CollectionProcessingWorkSummary: Sendable, Equatable {
  /// Folders eligible for processing on a later authorized invocation.
  public private(set) var needsProcessing: Int = .zero
  /// Folders waiting for a retry deadline, credential change, or recovery-mode exit.
  public private(set) var waitingToRetry: Int = .zero
  /// Conclusive outcomes requiring explicit user action or changed folder evidence.
  public private(set) var needsManualResolution: Int = .zero
  /// Legacy or uncertain evidence that requires a fresh assessment.
  public private(set) var needsReassessment: Int = .zero
  /// Verified installed posters retained independently of pending work.
  public private(set) var done: Int = .zero
  /// Existing icons intentionally retained.
  public private(set) var preserved: Int = .zero
  /// Folders intentionally excluded by saved policy.
  public private(set) var suppressed: Int = .zero
  /// Whether the inventory and current processing context support authoritative work counts.
  public let isKnown: Bool
  /// Whether all current folders have a verified or intentional terminal outcome.
  public var isComplete: Bool {
    isKnown && needsProcessing == .zero && waitingToRetry == .zero && needsManualResolution == .zero
      && needsReassessment == .zero
  }
  /// Safe mixed-condition labels, with freshness presented separately by the caller.
  public var description: String {
    if isComplete { return "Complete" }
    let counts = [
      ("Needs processing", needsProcessing), ("Waiting to retry", waitingToRetry),
      ("Needs manual resolution", needsManualResolution), ("Needs reassessment", needsReassessment)
    ]
    let observed = counts.filter { $0.1 > .zero }.map { "\($0.0): \($0.1)" }.joined(separator: " · ")
    guard isKnown else { return observed.isEmpty ? "Unknown" : "Unverified saved work · \(observed)" }

    return observed
  }

  /// Projects saved folder reasons without starting processing or clearing retry evidence.
  /// - Parameters:
  ///   - processingState: Persisted immediate-child evidence, when readable.
  ///   - isStale: Whether the saved context no longer matches current settings.
  ///   - now: Reference date for eligibility; no automatic retry is scheduled.
  public init(processingState: CollectionProcessingState?, isStale: Bool = false, now: Date = Date()) {
    isKnown = processingState?.hasKnownTotal == true && !isStale
    guard let processingState else { return }
    for folder in processingState.folders { classify(folder, now: now) }
  }

  /// Classifies one saved outcome while preserving terminal icon ownership evidence.
  private mutating func classify(_ folder: FolderProcessingRecord, now: Date) {
    if folder.isVerifiedDone { done += 1; return }
    if folder.state == .preserved { preserved += 1; return }
    if folder.state == .suppressed { suppressed += 1; return }
    if folder.state == .pending { needsProcessing += 1; return }
    if folder.state == .uncertain || folder.state == .done { needsReassessment += 1; return }
    guard let reason = folder.reason, reason != .unknown else { needsReassessment += 1; return }
    switch reason {
    case .noSuitableMovie, .ambiguousMovie, .parsingProblem, .missingArtwork, .manualIdentificationRequired:
      needsManualResolution += 1
    case .authentication, .recoveryMode:
      waitingToRetry += 1
    default:
      if let retryAt = folder.retryAt, retryAt > now { waitingToRetry += 1 } else { needsProcessing += 1 }
    }
  }
}
