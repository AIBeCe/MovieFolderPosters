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
    let activity = ProcessorActivityLog(context: activityLogContext, action: .automaticProcessing, child: child)
    do {
      let result = try await performRetryEligibleFolder(
        root: root, child: child, expectedIdentity: expectedIdentity,
        processingContext: processingContext, activity: activity)
      await flushActivityLog(activity)

      return result
    } catch {
      recordActivityFailure(error, in: activity)
      await flushActivityLog(activity)
      throw error
    }
  }

  /// Executes the operation while retaining its existing processing access and safety fences.
  private func performRetryEligibleFolder(
    root: URL, child: String, expectedIdentity: String,
    processingContext: CollectionProcessingContext, activity: ProcessorActivityLog
  ) async throws -> FolderRetryResult {
    try Task.checkCancellation()
    try recovery?.validateProcessingAllowed()
    let coordinationAccess = try acquireCoordinationAccess(for: root)
    defer { withExtendedLifetime(coordinationAccess) {} }

    guard let access = try persistence.acquireAccess(for: Self.processingStateKey(for: root)) else {
      throw PosterActionError.busy
    }

    defer { withExtendedLifetime(access) {} }

    guard let snapshot = try processingStore?.read(rootID: processingContext.rootID),
      snapshot.context == processingContext,
      let record = snapshot.folders.first(where: { $0.name == child })
    else { throw CollectionProcessingError.configurationChanged }

    guard record.identity == expectedIdentity else { throw PosterActionError.changedIdentity }

    let candidate = try actionCandidate(root: root, child: child, expectedIdentity: expectedIdentity)

    guard !record.isVerifiedDone, record.state != .preserved, record.state != .suppressed, record.state != .excluded,
      !processingConfiguration.excludesFolder(identity: candidate.identity),
      !candidate.hasCustomIcon,
      try !fileSystem.isPosterSuppressed(toChild: child, in: root) else { return .notEligible }

    if requiresManualReview(record.reason) { return .notEligible }

    let cache = try loadState(from: access)
    let prior = cache.folders[child]
    activity.movie = savedActivityMovie(prior, candidate: candidate)
    let sameFingerprint = prior?.fingerprint == candidate.fingerprint
    if sameFingerprint, prior?.blocksAutomaticRecovery == true { return .notEligible }
    let isLegacyUnresolvedResult = sameFingerprint && prior?.isLegacyUnresolvedResult == true
    if !isLegacyUnresolvedResult, let deadline = cache.providerRetryAt, deadline > now() {
      activity.append(.deferred, reason: .retryDeferred, retryAt: deadline)

      return .waiting(until: deadline)
    }
    if !isLegacyUnresolvedResult, prior?.processingReason != .interrupted, record.reason != .interrupted {
      let cacheDeadline = sameFingerprint ? prior?.retryDate : .none
      if let deadline = [cacheDeadline, record.retryAt].compactMap({ $0 }).max(), deadline > now() {
        activity.append(.deferred, reason: .retryDeferred, retryAt: deadline)

        return .waiting(until: deadline)
      }
    }

    do {
      let settingsAccess = try checkIconChange(.automaticPosterAssignment, to: candidate, in: root)
      withExtendedLifetime(settingsAccess) {}
    }

    var visit = AutomaticProcessingVisit(
      cache: cache, recording: try recordProcessingStart(context: processingContext, action: .manual, child: child),
      activity: activity, selectedChild: child)
    defer { interruptUnfinishedProcessing(&visit.recording, child: child) }

    if try !shouldSkipCandidate(candidate, root: root, visit: &visit),
      try await !reuseCachedDecision(candidate, root: root, access: access, visit: &visit) {
      visit.didStopEarly = try await processCandidate(candidate, root: root, access: access, visit: &visit)
    }

    try finishProcessingRun(
      &visit.recording, state: visit.didStopEarly ? .partial : .completed, activity: visit.activity)

    return .attempted(visit.summary, stopSelection: visit.didStopEarly)
  }

  /// Identifies conclusive outcomes that selected automatic retry must leave for explicit manual resolution.
  /// - Parameter reason: Persisted reason shown in the selected folder's current evidence.
  /// - Returns: Whether retry admission must reject this outcome as requiring manual action.
  private func requiresManualReview(_ reason: FolderProcessingReason?) -> Bool {
    switch reason {
    case .noSuitableMovie, .ambiguousMovie, .parsingProblem, .missingArtwork, .authentication,
         .manualMatchingRequired: true
    default: false
    }
  }
}
