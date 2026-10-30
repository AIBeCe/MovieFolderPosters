import FileSystem
import Foundation
import Network

/// One actor-confined operation's bounded immutable result events, flushed after its processing locks unwind.
final class ProcessorActivityLog {
  /// Trusted collection provenance captured by production composition.
  let context: MovieFolderActivityLogContext?
  /// The action owning all folder results in this operation.
  let action: MovieFolderActivityLogEvent.Action
  /// Opaque grouping shared by this operation's terminal folder events.
  let groupID = UUID()
  /// Newest events retained within the same bound as durable Activity history.
  private(set) var events: [MovieFolderActivityLogEvent] = []
  /// Prior committed folder results used only to avoid repeating unchanged preservation and inclusion decisions.
  var priorFolderResults: [String: FolderProcessingRecord] = [:]
  /// Current immediate-child name, captured before provider or icon work begins.
  var child: String?
  /// Confirmed identity, populated only after a match or verified saved decision.
  var movie: MovieMetadata?
  /// Most recent actual operation boundary used for safe error reporting.
  var stage: FolderProcessingStage = .validateIdentity
  /// Whether the current child already has a recorded terminal operation result.
  private(set) var hasTerminalResult = false
  /// Whether a required persistence failure has already been reported for the current child.
  private var hasRecordedPersistenceFailure = false

  /// Creates a buffer without opening history storage or acquiring configuration access.
  init(context: MovieFolderActivityLogContext?, action: MovieFolderActivityLogEvent.Action, child: String? = .none) {
    self.context = context
    self.action = action
    self.child = child
  }

  /// Begins a new folder attempt without reusing another folder's confirmed identity.
  /// - Parameters:
  ///   - child: The immediate child folder name for this attempt.
  ///   - movie: A confirmed movie identity, when available.
  ///   - stage: The operation stage where the attempt begins.
  func begin(_ child: String, movie: MovieMetadata? = .none, stage: FolderProcessingStage = .validateIdentity) {
    self.child = child
    self.movie = movie
    self.stage = stage
    hasTerminalResult = false
    hasRecordedPersistenceFailure = false
  }

  /// Captures an actual terminal result using fixed typed facts, without writing while processing locks are held.
  /// - Parameters:
  ///   - result: The terminal outcome for the current folder.
  ///   - reason: The processing reason, when known.
  ///   - failure: Safe failure evidence, when the operation failed.
  ///   - retryAt: The earliest retry eligibility time for the folder or provider, when known.
  func append(
    _ result: MovieFolderActivityLogEvent.FolderResult, reason: FolderProcessingReason? = .none,
    failure: FolderProcessingFailure? = .none, retryAt: Date? = .none
  ) {
    hasTerminalResult = true
    if failure?.stage == .persist { hasRecordedPersistenceFailure = true }

    guard let context else { return }

    let status: MovieFolderActivityLogEvent.Status = switch result {
    case .failed: .failed
    case .cancelled: .cancelled
    case .deferred: .partial
    default: .succeeded
    }
    events.append(context.event(
      action: action, status: status, activityGroupID: groupID, childFolderName: child,
      movieID: movie?.id, movieTitle: movie?.title.isEmpty == false ? movie?.title : .none,
      movieYear: movie?.releaseYear,
      folderResult: result, reason: reason, failure: failure, retryAt: retryAt))
    if events.count > 500 { events.removeFirst(events.count - 500) }
  }

  /// Retains an actual required write failure alongside any already completed icon or matching operation.
  /// - Parameter failure: The required persistence failure to retain.
  func appendPersistenceFailure(_ failure: FolderProcessingFailure) {
    guard !hasRecordedPersistenceFailure else { return }

    append(.failed, reason: failure.reason == .storage ? .storageUnavailable : .processingFailure, failure: failure)
  }

  /// Captures this attempt's folder result rather than reconstructing the latest stored folder after the run.
  /// - Parameters:
  ///   - record: The folder result produced by this operation.
  ///   - onlyWhenChanged: Whether to omit a result identical to the prior saved result.
  ///   - failure: Safe failure evidence associated with this result, when present.
  func append(
    _ record: FolderProcessingRecord, onlyWhenChanged: Bool = false, failure: FolderProcessingFailure? = .none
  ) {
    if onlyWhenChanged, let previous = priorFolderResults[record.name], previous.identity == record.identity,
      previous.state == record.state, previous.reason == record.reason, previous.movieID == record.movieID {
      return
    }
    child = record.name
    movie = record.movieID.map {
      MovieMetadata(id: $0, title: record.movieTitle ?? "", originalTitle: record.movieTitle ?? "",
        releaseYear: record.movieYear, posterPath: .none)
    }
    let result: MovieFolderActivityLogEvent.FolderResult
    switch record.state {
    case .notFound: result = .notFound
    case .severalMatches: result = .severalMatches
    case .unresolved, .uncertain: result = .unresolved
    case .preserved: result = .preserved
    case .suppressed: result = .suppressed
    case .excluded: result = .excluded
    case .deferred: result = .deferred
    case .failed: result = .failed
    case .pending, .done: return
    }
    append(result, reason: record.reason, failure: failure ?? record.lastFailure, retryAt: record.retryAt)
  }
}

extension MovieFolderProcessor {
  /// Supplies only a saved identity whose fingerprint still identifies this child.
  /// - Parameters:
  ///   - record: The saved folder decision, when one exists.
  ///   - candidate: The currently inspected child whose fingerprint must match the saved decision.
  /// - Returns: The saved movie identity when it is still tied to this child.
  func savedActivityMovie(_ record: FolderRecord?, candidate: FolderCandidate) -> MovieMetadata? {
    guard let record, record.fingerprint == candidate.fingerprint, let movieID = record.matchedMovieID else {
      return .none
    }

    return MovieMetadata(id: movieID, title: record.movieTitle ?? "", originalTitle: record.movieTitle ?? "",
      releaseYear: record.movieYear, posterPath: record.posterPath)
  }

  /// Flushes best-effort reporting only after the operation's configuration, recovery and root locks have unwound.
  /// - Parameter activity: The buffered operation events to record.
  func flushActivityLog(_ activity: ProcessorActivityLog) async {
    guard let activityHistoryService else { return }

    for event in activity.events { await activityHistoryService.record(event) }
  }

  /// Captures a thrown operation's active folder and safe stage without changing the error returned to the caller.
  /// - Parameters:
  ///   - error: The error thrown by the operation.
  ///   - activity: The operation buffer receiving its terminal failure event.
  func recordActivityFailure(_ error: any Error, in activity: ProcessorActivityLog) {
    guard activity.child != .none, !activity.hasTerminalResult else { return }

    let cancelled = error is CancellationError || Task.isCancelled
    let failure = cancelled
      ? FolderProcessingFailure(reason: .cancelled, stage: activity.stage, occurredAt: now())
      : MovieFolderActivityLogEvent.failureEvidence(for: error, stage: activity.stage, occurredAt: now())
    let reason: FolderProcessingReason = switch failure.reason {
    case .cancelled: .interrupted
    case .authentication: .authentication
    case .rateLimited: .rateLimited
    case .connectivity, .timeout: .connectivity
    case .serverFailure: .serverFailure
    case .invalidResponse: .invalidResponse
    case .filesystem, .authorizationDenied: .filesystemFailure
    case .ownershipChanged: .ownershipChanged
    case .storage: .storageUnavailable
    case .capacity: .capacityExceeded
    case .recoveryMode: .recoveryMode
    case .folderExcluded: .explicitExclusion
    default: .processingFailure
    }
    let retryAt: Date?
    if case ProcessingRecoveryError.providerBackoff(let until, _) = error {
      retryAt = until
    } else {
      retryAt = .none
    }
    activity.append(cancelled ? .cancelled : .failed, reason: reason, failure: failure, retryAt: retryAt)
  }
}
