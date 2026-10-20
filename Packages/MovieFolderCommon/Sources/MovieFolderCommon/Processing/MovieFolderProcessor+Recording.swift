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
  func commitProcessingState(_ processingState: inout CollectionProcessingState?) throws {
    guard let processingStore, let current = processingState else { return }
    do {
      processingState = try processingStore.commit(current, expectedRevision: current.revision)
    } catch let error as CollectionProcessingError {
      throw error
    } catch {
      // Storage errors must escape folder recovery before any subsequent icon mutation.
      throw CollectionProcessingError.unavailable
    }
  }

  /// Marks unfinished work conservatively when cancellation or an error exits the operation.
  func interruptUnfinishedProcessing(_ processingState: inout CollectionProcessingState?) {
    guard processingState?.operation?.state == .running else { return }
    if let folders = processingState?.folders {
      processingState?.folders = folders.map { record in
        guard record.state == .pending else { return record }
        var uncertain = record
        uncertain.state = .uncertain
        uncertain.reason = .interrupted

        return uncertain
      }
    }
    try? finishProcessingOperation(&processingState, state: Task.isCancelled ? .interrupted : .failed)
  }

  /// Rechecks installed evidence after a failed action while keeping its failed attempt separate.
  func recoverManualProcessing(
    _ processingState: inout CollectionProcessingState?, root: URL, child: String, saved: FolderRecord?
  ) {
    guard processingState?.operation?.state == .running else { return }
    if let candidate = try? fileSystem.readCurrentState(ofChild: child, in: root),
      var record = try? assessFolderProcessing(candidate, root: root, saved: saved) {
      record.lastFailure = FolderProcessingFailure(
        reason: Task.isCancelled ? .cancelled : .unknown, stage: .unknown, occurredAt: now())
      if record.state != .done && record.state != .preserved && record.state != .suppressed {
        record.state = .uncertain
        record.reason = .interrupted
      }
      try? recordFolderProcessing(record, in: &processingState)
    }
    try? finishProcessingOperation(&processingState, state: Task.isCancelled ? .interrupted : .failed)
  }

  /// Ends one attempt without confusing action completion with a completed collection traversal.
  func finishProcessingOperation(
    _ processingState: inout CollectionProcessingState?, state: CollectionProcessingOperationState
  ) throws {
    guard processingState != .none else { return }
    processingState?.operation?.state = state
    processingState?.operation?.endedAt = now()
    if state == .completed,
      processingState?.operation?.action == .automatic,
      processingState?.isInventoryComplete == true {
      let completed = processingState?.operation
      processingState?.lastCompletedRun = completed
    }
    try commitProcessingState(&processingState)
  }

  /// Updates one member and bounds whole-document checkpoint writes to batches of 32 assessments.
  func recordFolderProcessing(
    _ record: FolderProcessingRecord,
    in processingState: inout CollectionProcessingState?
  ) throws {
    guard processingState != .none else { return }
    guard let index = processingState?.folders.firstIndex(where: { $0.name == record.name }) else {
      throw CollectionProcessingError.invalidState
    }
    processingState?.folders[index] = record
    let assessed = processingState?.folders.lazy.filter { $0.state != .pending }.count ?? .zero
    if assessed.isMultiple(of: 32) { try commitProcessingState(&processingState) }
  }

  /// Explains a root backoff for members that have not yet been assessed.
  func deferPendingFolderAssessments(_ processingState: inout CollectionProcessingState?, until date: Date) {
    guard let current = processingState else { return }
    processingState?.folders = current.folders.map { record in
      guard record.state == .pending else { return record }
      var deferred = record
      deferred.state = .deferred
      deferred.reason = .retryDeferred
      deferred.retryAt = date
      deferred.assessedAt = now()

      return deferred
    }
  }

  /// Converts conservative matching evidence to its exclusive persisted state.
  func unresolvedFolderAssessment(
    _ candidate: FolderCandidate, reason: FolderProcessingReason, movie: MovieMetadata? = .none
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
      retryAt: reason == .incompleteSearch ? now().addingTimeInterval(Self.unresolvedRetryInterval) : .none,
      fingerprint: candidate.fingerprint)
  }

  /// Preserves the original unresolved reason while existing retry policy defers another provider request.
  func cachedFolderAssessment(_ candidate: FolderCandidate, saved: FolderRecord) -> FolderProcessingRecord {
    var record = unresolvedFolderAssessment(candidate, reason: saved.processingReason ?? .retryDeferred)
    if saved.status == .transientFailure {
      record.state = .failed
      record.reason = saved.processingReason ?? .processingFailure
      record.lastFailure = saved.lastFailure
    } else if saved.processingReason == .none {
      record.state = .deferred
    }
    record.retryAt = saved.blocksAutomaticRecovery || saved.processingReason == .authentication
      ? .none : saved.retryDate
    record.movieID = saved.matchedMovieID
    record.movieTitle = saved.movieTitle
    record.movieYear = saved.movieYear
    record.movieIdentitySource = saved.movieIdentitySource ?? (saved.matchedMovieID == .none ? .none : .savedDecision)

    return record
  }

  /// Records a failure without embedding provider messages or private paths.
  func failedFolderAssessment(
    _ candidate: FolderCandidate, stage: FolderProcessingStage, movie: MovieMetadata? = .none,
    reason: FolderProcessingReason? = .none, failureReason: FolderProcessingFailureReason = .unavailable
  ) -> FolderProcessingRecord {
    FolderProcessingRecord(
      name: candidate.name, identity: candidate.identity, state: .failed,
      reason: reason ??
        (stage == .search ? .metadataFailure : (stage == .artwork ? .posterFailure : .filesystemFailure)),
      movieID: movie?.id, movieTitle: movie?.title, movieYear: movie?.releaseYear,
      movieIdentitySource: movie == .none ? .none : .conservativeMatch,
      assessedAt: now(),
      retryAt: reason == .authentication ? .none : now().addingTimeInterval(Self.transientRetryInterval),
      lastFailure: FolderProcessingFailure(reason: failureReason, stage: stage, occurredAt: now()),
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
  func assessFolderProcessing(
    _ candidate: FolderCandidate, root: URL, saved: FolderRecord?
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
      record.movieID = saved.matchedMovieID
      record.movieTitle = saved.movieTitle
      record.movieYear = saved.movieYear
      record.movieIdentitySource = saved.movieIdentitySource ?? (saved.matchedMovieID == .none ? .none : .savedDecision)
    }
    if inspection.isSuppressed {
      record.state = .suppressed
      record.reason = .policySuppressed
    } else if record.ownership == .owned, (record.movieID ?? .zero) > .zero {
      record.state = .done
    } else if record.ownership == .unowned || record.ownership == .changed {
      record.state = .preserved
      record.reason = record.ownership == .changed ? .ownershipChanged : .existingPosterPreserved
    } else {
      record.state = .unresolved
      record.reason = .savedIdentityUnavailable
    }

    return record
  }
}
