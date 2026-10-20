import FileSystem
import Foundation
import Persistence

extension MovieFolderProcessor {
  /// Retries only the selected folder while preserving confirmed outcomes and current retry boundaries.
  ///
  /// - Parameters:
  ///   - root: The authorized collection root containing the selected immediate child.
  ///   - child: The selected immediate child name, without additional path components.
  ///   - expectedIdentity: The filesystem identity captured with the selection.
  ///   - processingContext: The exact authoritative root and settings generation shown to the user.
  /// - Returns: An attempt summary, an unchanged ineligible outcome, or the current retry deadline.
  /// - Throws: Cancellation, contention, stale configuration, changed identity, or persistence errors.
  public func retryEligibleFolder(
    root: URL, child: String, expectedIdentity: String, processingContext: CollectionProcessingContext
  ) async throws -> FolderRetryResult {
    try Task.checkCancellation()
    try recovery?.validateProcessingAllowed()
    let coordinationLease = try acquireCoordinationLease(for: root)
    defer { withExtendedLifetime(coordinationLease) {} }
    guard let lease = try persistence.acquireLease(for: Self.rootLeaseKey(for: root)) else {
      throw PosterActionError.busy
    }
    defer { withExtendedLifetime(lease) {} }
    guard let snapshot = try processingStore?.read(rootID: processingContext.rootID),
      snapshot.context == processingContext,
      let record = snapshot.folders.first(where: { $0.name == child })
    else { throw CollectionProcessingError.configurationChanged }
    guard record.identity == expectedIdentity else { throw PosterActionError.changedIdentity }
    let candidate = try actionCandidate(root: root, child: child, expectedIdentity: expectedIdentity)
    guard !record.isVerifiedDone, record.state != .preserved, record.state != .suppressed,
      !candidate.hasCustomIcon,
      try !fileSystem.isPosterSuppressed(toChild: child, in: root) else { return .notEligible }
    switch record.reason {
    case .noSuitableMovie, .ambiguousMovie, .parsingProblem, .missingArtwork, .authentication:
      return .notEligible
    default: break
    }
    let cache = try loadState(from: lease)
    let prior = cache.folders[child]
    let sameFingerprint = prior?.fingerprint == candidate.fingerprint
    if sameFingerprint, prior?.blocksAutomaticRecovery == true { return .notEligible }
    let needsLegacyReassessment = sameFingerprint && prior?.needsLegacyReassessment == true
    if !needsLegacyReassessment, let deadline = cache.rootBackoffUntil, deadline > now() {
      return .waiting(until: deadline)
    }
    if !needsLegacyReassessment, prior?.processingReason != .interrupted, record.reason != .interrupted {
      let cacheDeadline = sameFingerprint ? prior?.retryDate : .none
      if let deadline = [cacheDeadline, record.retryAt].compactMap({ $0 }).max(), deadline > now() {
        return .waiting(until: deadline)
      }
    }
    do {
      let settingsLease = try mutationGuard?.movieFolderProcessorWillPerformManualMutation(self)
      withExtendedLifetime(settingsLease) {}
    }
    var visit = AutomaticProcessingVisit(
      cache: cache, recording: try recordProcessingStart(context: processingContext, action: .manual, child: child),
      selectedChild: child)
    defer { interruptUnfinishedProcessing(&visit.recording, child: child) }
    if try !shouldSkipCandidate(candidate, root: root, visit: &visit),
      try !reuseCachedDecision(candidate, root: root, lease: lease, visit: &visit) {
      visit.didStopEarly = try await processCandidate(candidate, root: root, lease: lease, visit: &visit)
    }
    try finishProcessingOperation(&visit.recording, state: visit.didStopEarly ? .partial : .completed)

    return .attempted(visit.summary, stopSelection: visit.didStopEarly)
  }
}
