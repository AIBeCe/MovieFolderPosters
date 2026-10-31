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
      let record = snapshot.folders.first(where: { $0.folderName == child })
    else { throw CollectionProcessingError.configurationChanged }

    guard record.folderIdentity == expectedIdentity else { throw PosterActionError.changedIdentity }

    let candidate = try actionCandidate(root: root, child: child, expectedIdentity: expectedIdentity)

    guard !record.isVerifiedDone, record.processingState != .preserved, record.processingState != .suppressed,
      record.processingState != .excluded,
      !processingConfiguration.excludesFolder(identity: candidate.identity),
      !candidate.hasCustomIcon,
      try !fileSystem.isPosterSuppressed(toChild: child, in: root) else { return .notEligible }

    if requiresManualReview(record.processingReason) { return .notEligible }

    let cache = try loadState(from: access)
    let prior = cache.folders[child]
    activity.movie = savedActivityMovie(prior, candidate: candidate)
    let sameFingerprint = prior?.fingerprint == candidate.fingerprint
    if sameFingerprint, prior?.blocksAutomaticRecovery == true { return .notEligible }
    let isLegacyUnresolvedResult = sameFingerprint && prior?.isLegacyUnresolvedResult == true
    let retryContext = SelectedFolderRetryDelayContext(
      saved: record, prior: prior, cache: cache, sameFingerprint: sameFingerprint,
      isLegacyUnresolvedResult: isLegacyUnresolvedResult, activity: activity)
    if let waiting = retryWait(retryContext) { return waiting }

    do {
      let settingsAccess = try checkIconChange(.automaticPosterAssignment, to: candidate, in: root)
      withExtendedLifetime(settingsAccess) {}
    }

    var visit = AutomaticProcessingPass(
      processingCache: cache, collectionProcessingRecord: try recordProcessingStart(context: processingContext, action: .manual, child: child),
      activityLog: activity, selectedRetryChildName: child)
    defer { interruptUnfinishedProcessing(&visit.collectionProcessingRecord, child: child) }

    if try !shouldSkipCandidate(candidate, root: root, visit: &visit),
      try await !reuseCachedDecision(candidate, root: root, access: access, visit: &visit) {
      visit.providerAdmissionStoppedPass = try await processCandidate(candidate, root: root, access: access, visit: &visit)
    }

    try finishProcessingRun(
      &visit.collectionProcessingRecord, state: visit.providerAdmissionStoppedPass ? .partial : .completed, activity: visit.activityLog)

    return .attempted(visit.processingSummary, stopSelection: visit.providerAdmissionStoppedPass)
  }

  /// Returns a saved provider or folder retry deadline unless the selected result is legacy or interrupted.
  /// - Parameter context: Saved retry evidence and the activity log for this attempt.
  /// - Returns: The retry deadline when the selection must remain waiting.
  private func retryWait(_ context: SelectedFolderRetryDelayContext) -> FolderRetryResult? {
    guard !context.isLegacyUnresolvedResult else { return .none }

    if let deadline = context.cache.providerRetryAt, deadline > now() {
      context.activity.append(.deferred, reason: .retryDeferred, retryAt: deadline)

      return .waiting(until: deadline)
    }

    guard context.prior?.processingReason != .interrupted,
      context.saved.processingReason != .interrupted else { return .none }
    let cacheDeadline = context.sameFingerprint ? context.prior?.retryDate : .none
    guard let deadline = [cacheDeadline, context.saved.nextRetryAt].compactMap({ $0 }).max(), deadline > now() else {
      return .none
    }
    context.activity.append(.deferred, reason: .retryDeferred, retryAt: deadline)

    return .waiting(until: deadline)
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

/// Saved evidence used to decide whether one selected folder may retry now.
private struct SelectedFolderRetryDelayContext {
  /// Current user-visible outcome for the selected child.
  let saved: FolderProcessingRecord
  /// Operational cache evidence for the same child, if present.
  let prior: FolderProcessingCacheRecord?
  /// Root-local provider retry state.
  let cache: CollectionProcessingCache
  /// Whether operational evidence belongs to the current child fingerprint.
  let sameFingerprint: Bool
  /// Whether legacy unresolved state permits a user-requested immediate retry.
  let isLegacyUnresolvedResult: Bool
  /// Activity log receiving a deferred event.
  let activity: ProcessorActivityLog
}
