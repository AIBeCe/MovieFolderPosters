import FileSystem
import Foundation
import Network
import Persistence

extension MovieFolderProcessor {
  // MARK: - Authoritative result recording
  /// Starts a recorded operation only when production supplied both its store and current context.
  func recordProcessingStart(
    context: CollectionProcessingContext?, action: CollectionProcessingAction, child: String? = .none
  ) throws -> CollectionProcessingState? {
    guard let processingStore else { return .none }
    guard let context else { throw CollectionProcessingError.configurationChanged }

    return try processingStore.recordProcessingStart(context: context, action: action, child: child, now: now())
  }

  /// Commits a complete revision while preserving the caller's expected operation and revision.
  func commitProcessingState(
    _ processingState: inout CollectionProcessingState?, activity: ProcessorActivityLog? = .none
  ) throws {
    guard let processingStore, let current = processingState else { return }
    do {
      processingState = try processingStore.commit(current, expectedRevision: current.revision)
    } catch let error as CollectionProcessingError {
      activity?.appendPersistenceFailure(
        MovieFolderActivityLogEvent.failureEvidence(for: error, stage: .persist, occurredAt: now()))
      throw error
    } catch {
      activity?.appendPersistenceFailure(AutomaticFolderProcessingFailure(reason: .storage, stage: .persist, occurredAt: now()))
      // Storage errors must escape folder recovery before any subsequent icon change.
      throw CollectionProcessingError.unavailable
    }
  }

  /// Marks unfinished work conservatively when cancellation or an error exits the operation.
  func interruptUnfinishedProcessing(_ processingState: inout CollectionProcessingState?, child: String? = .none) {
    guard processingState?.currentRun?.runState == .running else { return }
    if let folders = processingState?.folders {
      processingState?.folders = folders.map { record in
        guard record.processingState == .pending, child == .none || record.folderName == child else { return record }
        var uncertain = record
        uncertain.processingState = .uncertain
        uncertain.processingReason = .interrupted

        return uncertain
      }
    }
    try? finishProcessingRun(&processingState, state: Task.isCancelled ? .interrupted : .failed)
  }

  /// Rechecks installed evidence after a failed action while keeping its failed attempt separate.
  func recoverManualProcessing(
    _ processingState: inout CollectionProcessingState?, root: URL, child: String, saved: FolderProcessingCacheRecord?
  ) {
    guard processingState?.currentRun?.runState == .running else { return }
    if let candidate = try? fileSystem.readCurrentFolderCandidate(ofChild: child, in: root),
      var record = try? folderProcessingResult(candidate, root: root, saved: saved) {
      record.lastFailure = AutomaticFolderProcessingFailure(
        reason: Task.isCancelled ? .cancelled : .unknown, stage: .unknown, occurredAt: now())
      if record.processingState != .done && record.processingState != .preserved && record.processingState != .suppressed {
        record.processingState = .uncertain
        record.processingReason = .interrupted
      }
      try? recordFolderProcessing(record, in: &processingState)
    }
    try? finishProcessingRun(&processingState, state: Task.isCancelled ? .interrupted : .failed)
  }

  /// Ends one attempt without confusing action completion with a completed collection traversal.
  func finishProcessingRun(
    _ processingState: inout CollectionProcessingState?, state: CollectionProcessingRunState,
    activity: ProcessorActivityLog? = .none
  ) throws {
    guard processingState != .none else { return }
    processingState?.currentRun?.runState = state
    processingState?.currentRun?.endedAt = now()
    if state == .completed,
      processingState?.currentRun?.action == .automatic,
      processingState?.isInventoryComplete == true {
      let completed = processingState?.currentRun
      processingState?.lastCompletedRun = completed
    }
    try commitProcessingState(&processingState, activity: activity)
  }

  /// Updates one member and bounds whole-document checkpoint writes to batches of 32 folder results.
  func recordFolderProcessing(
    _ record: FolderProcessingRecord,
    in processingState: inout CollectionProcessingState?, activity: ProcessorActivityLog? = .none
  ) throws {
    guard processingState != .none else { return }
    guard let index = processingState?.folders.firstIndex(where: { $0.folderName == record.folderName }) else {
      throw CollectionProcessingError.invalidState
    }
    processingState?.folders[index] = record
    let assessed = processingState?.folders.lazy.filter { $0.processingState != .pending }.count ?? .zero
    if assessed.isMultiple(of: 32) { try commitProcessingState(&processingState, activity: activity) }
  }

  /// Explains a root backoff for members that have not yet been assessed.
  func deferPendingFolderResults(
    _ processingState: inout CollectionProcessingState?, until date: Date, child: String? = .none,
    activity: ProcessorActivityLog? = .none
  ) {
    guard let current = processingState else { return }
    processingState?.folders = current.folders.map { record in
      guard record.processingState == .pending, child == .none || record.folderName == child else { return record }
      var deferred = record
      deferred.processingState = .deferred
      deferred.processingReason = .retryDeferred
      deferred.nextRetryAt = date
      deferred.assessedAt = now()
      activity?.append(deferred)

      return deferred
    }
  }

  /// Converts conservative matching evidence to its exclusive persisted state.
  func unresolvedFolderResult(
    _ candidate: MovieFolderCandidate, reason: FolderProcessingReason, movie: MovieMetadata? = .none
  ) -> FolderProcessingRecord {
    let state: FolderProcessingState
    switch reason {
    case .noSuitableMovie: state = .notFound
    case .ambiguousMovie: state = .severalMatches
    default: state = .unresolved
    }

    return FolderProcessingRecord(
      name: candidate.name, identity: candidate.identity, state: state, reason: reason,
      movieID: movie?.id, movieTitle: movie?.title, movieYear: movie?.releaseYear,
      movieIdentitySource: movie == .none ? .none : .conservativeMatch,
      ownership: .none, assessedAt: now(),
      retryAt: reason == .incompleteSearch
        ? now().addingTimeInterval(configuration.incompleteSearchRetryInterval) : .none,
      fingerprint: candidate.fingerprint)
  }

  /// Preserves the original unresolved reason while existing retry configuration defers another provider request.
  func cachedFolderResult(_ candidate: MovieFolderCandidate, saved: FolderProcessingCacheRecord) -> FolderProcessingRecord {
    var record = unresolvedFolderResult(candidate, reason: saved.processingReason ?? .retryDeferred)
    if saved.status == .transientFailure {
      record.processingState = .failed
      record.processingReason = saved.processingReason ?? .processingFailure
      record.lastFailure = saved.lastFailure
    } else if saved.processingReason == .none {
      record.processingState = .deferred
    }
    record.nextRetryAt = saved.blocksAutomaticRecovery || saved.processingReason == .authentication
      ? .none : saved.retryDate
    record.matchedMovieID = saved.matchedMovieID
    record.matchedMovieTitle = saved.movieTitle
    record.matchedMovieYear = saved.movieYear
    record.movieIdentitySource = saved.movieIdentitySource ?? (saved.matchedMovieID == .none ? .none : .savedDecision)

    return record
  }

  /// Records a failure without embedding provider messages or private paths.
  func failedFolderResult(
    _ candidate: MovieFolderCandidate, stage: FolderProcessingStage, movie: MovieMetadata? = .none,
    reason: FolderProcessingReason? = .none, failureReason: FolderProcessingFailureReason = .unavailable
  ) -> FolderProcessingRecord {
    FolderProcessingRecord(
      name: candidate.name, identity: candidate.identity, state: .failed,
      reason: reason ??
        (stage == .search ? .metadataFailure : (stage == .artwork ? .posterFailure : .filesystemFailure)),
      movieID: movie?.id, movieTitle: movie?.title, movieYear: movie?.releaseYear,
      movieIdentitySource: movie == .none ? .none : .conservativeMatch,
      assessedAt: now(),
      retryAt: reason == .authentication
        ? .none : now().addingTimeInterval(configuration.transientFailureRetryInterval),
      lastFailure: AutomaticFolderProcessingFailure(reason: failureReason, stage: stage, occurredAt: now()),
      fingerprint: candidate.fingerprint)
  }

  /// Converts provider failures to stable categories without retaining status text or private request details.
  func providerFailureEvidence(
    _ error: TMDbError, stage: FolderProcessingStage
  ) -> (reason: FolderProcessingReason, failureReason: FolderProcessingFailureReason) {
    switch error {
    case .authentication, .missingToken, .httpStatus(401), .httpStatus(403):
      return (.authentication, .authentication)
    case .rateLimited, .httpStatus(429):
      return (.rateLimited, .rateLimited)
    case .transport(let code):
      return (.connectivity, code == NSURLErrorTimedOut ? .timeout : .connectivity)
    case .httpStatus(let code) where (500...599).contains(code):
      return (.serverFailure, .serverFailure)
    case .malformedResponse, .invalidImage, .invalidPosterPath, .invalidConfiguration, .responseTooLarge:
      return (.invalidResponse, .invalidResponse)
    default:
      return (stage == .artwork ? .posterFailure : .metadataFailure, .unavailable)
    }
  }

  /// Verifies current ownership instead of treating an assignment attempt or cached decision as success.
  func folderProcessingResult(
    _ candidate: MovieFolderCandidate, root: URL, saved: FolderProcessingCacheRecord?
  ) throws -> FolderProcessingRecord {
    let inspection = try fileSystem.inspectPoster(
      toChild: candidate.name, in: root, expectedIdentity: candidate.identity)
    var record = FolderProcessingRecord(
      name: candidate.name, identity: candidate.identity, state: .pending,
      assessedAt: now(), fingerprint: candidate.fingerprint)
    switch inspection.ownership {
    case .none: record.ownership = .none
    case .owned: record.ownership = .owned
    case .unowned: record.ownership = .unowned
    case .changed: record.ownership = .changed
    }
    if let saved, saved.fingerprint == candidate.fingerprint {
      record.matchedMovieID = saved.matchedMovieID
      record.matchedMovieTitle = saved.movieTitle
      record.matchedMovieYear = saved.movieYear
      record.movieIdentitySource = saved.movieIdentitySource ?? (saved.matchedMovieID == .none ? .none : .savedDecision)
    }
    if inspection.isSuppressed {
      record.processingState = .suppressed
      record.processingReason = .policySuppressed
    } else if record.ownership == .owned, (record.matchedMovieID ?? .zero) > .zero {
      record.processingState = .done
    } else if record.ownership == .unowned || record.ownership == .changed {
      record.processingState = .preserved
      record.processingReason = record.ownership == .changed ? .ownershipChanged : .existingPosterPreserved
    } else {
      record.processingState = .unresolved
      record.processingReason = .savedIdentityUnavailable
    }

    return record
  }
}
