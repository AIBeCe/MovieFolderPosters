import FileSystem
import Foundation
import MovieFolderParsing
import Network
import Persistence

extension MovieFolderProcessor {
  /// Reuses unchanged decisions and reports whether this member is already handled.
  func reuseCachedDecision(
    _ candidate: MovieFolderCandidate, root: URL, access: PersistenceAccess, visit: inout AutomaticProcessingPass
  ) async throws -> Bool {
    let priorRecord = visit.processingCache.folders[candidate.name]
    let sameFingerprint = priorRecord?.fingerprint == candidate.fingerprint

    if sameFingerprint, let record = priorRecord {
      // An existing owned icon is assessed separately. An absent icon needs a current-configuration decision.
      if record.requiresAutomaticReview == true { return false }

      let needsMatchingReview = needsMatchingReview(candidate, saved: record)
      let needsParserReview = needsParserReview(candidate, saved: record)

      if !needsParserReview, !needsMatchingReview,
        record.blocksAutomaticRecovery || (record.processingReason == .authentication && recovery == nil) {
        visit.processingSummary.unresolved += 1
        try recordFolderProcessing(
          cachedFolderResult(candidate, saved: record), in: &visit.collectionProcessingRecord, activity: visit.activityLog)
        return true
      }

      let canReuseSavedArtwork = record.status == .processed ||
        (record.status == .transientFailure &&
          (record.lastFailure?.stage == .artwork || record.lastFailure?.stage == .assignPoster)
          && (record.retryDate ?? .distantPast) <= now()) ||
        (record.status == .transientFailure && record.matchedMovieID != .none && record.posterPath != .none
          && record.lastFailure == .none && record.processingReason == .none)

      if canReuseSavedArtwork, let movieID = record.matchedMovieID, let posterPath = record.posterPath {
        let assignment: SavedFolderPosterAssignment
        switch cachedPoster(for: posterPath) {
        case .valid(let bytes):
          assignment = SavedFolderPosterAssignment(bytes: bytes, movieID: movieID, posterPath: posterPath, record: record)
        case .missing, .invalid:
          let decision = SavedPosterDecision(movieID: movieID, posterPath: posterPath, record: record)
          let context = ArtworkRepairContext(candidate: candidate, root: root, access: access)
          return try await repairCachedPoster(
            decision, context: context, visit: &visit)
        }

        try assignCachedPoster(assignment, candidate: candidate, root: root, access: access, visit: &visit)
        return true
      }

      if try shouldDeferCachedRetry(candidate, saved: record, needsParserReview: needsParserReview,
        needsMatchingReview: needsMatchingReview, visit: &visit) { return true }

      if record.isLegacyUnresolvedResult || record.processingReason == .incompleteSearch || needsParserReview
        || needsMatchingReview,
        case .parsed(let parsed) = parser.parse(candidate.name) {
        // A retry must not establish a new classification from the same inconclusive search.
        visit.processingCache.queries.removeValue(forKey: try Self.queryKey(title: parsed.title, year: .none,
          language: movieMatchingConfiguration.searchLanguage, credentialRevision: credentialRevision,
          usesFixtures: usesFixtureMetadata))
        visit.processingCache.folders[candidate.name] = FolderProcessingCacheRecord(
          fingerprint: candidate.fingerprint, status: .transientFailure, retryDate: .none,
          matchedMovieID: record.matchedMovieID, posterPath: record.posterPath, processingReason: .interrupted,
          movieTitle: record.movieTitle, movieYear: record.movieYear, movieIdentitySource: record.movieIdentitySource)
        try saveState(visit.processingCache, to: access, activity: visit.activityLog)
      }
    }

    return false
  }

  /// Records a saved retry deadline when no new parser or matching rules require another attempt.
  /// - Parameters:
  ///   - candidate: Current folder identity and name.
  ///   - record: Saved retry outcome.
  ///   - needsParserReview: Whether the current parser requires a fresh attempt.
  ///   - needsMatchingReview: Whether current matching rules require a fresh attempt.
  ///   - visit: Processing state receiving the deferred result.
  /// - Returns: Whether the saved deadline handled the candidate.
  /// - Throws: An authoritative result persistence error.
  private func shouldDeferCachedRetry(
    _ candidate: MovieFolderCandidate, saved record: FolderProcessingCacheRecord, needsParserReview: Bool,
    needsMatchingReview: Bool, visit: inout AutomaticProcessingPass
  ) throws -> Bool {
    guard record.status != .processed, !record.isLegacyUnresolvedResult,
      !needsParserReview, !needsMatchingReview,
      record.processingReason != .interrupted, let retryDate = record.retryDate, retryDate > now() else {
      return false
    }

    visit.processingSummary.skippedRetryWindow += 1
    visit.activityLog?.movie = savedActivityMovie(record, candidate: candidate)
    visit.activityLog?.append(.deferred, reason: .retryDeferred, retryAt: record.retryDate)
    try recordFolderProcessing(
      cachedFolderResult(candidate, saved: record), in: &visit.collectionProcessingRecord, activity: visit.activityLog)

    return true
  }

  /// Detects an unchanged unresolved name whose parser revision permits fresh classification.
  /// - Parameters:
  ///   - candidate: Current folder identity and name.
  ///   - record: Saved unresolved decision for that folder.
  /// - Returns: Whether the saved decision needs a parser review.
  private func needsParserReview(_ candidate: MovieFolderCandidate, saved record: FolderProcessingCacheRecord) -> Bool {
    record.status == .unresolved
      && record.nameParserRevision != ReleaseNameParser.revision
      && (record.processingReason == .parsingProblem || record.processingReason == .noSuitableMovie
        || record.processingReason == .ambiguousMovie)
      && (parser.hasRecognizedDatabaseIdentifierSuffix(candidate.name)
        || parser.hasRecognizedEditionSuffix(candidate.name))
  }

  /// Reconsiders only older unresolved automatic year results, leaving confirmed and explicit identities intact.
  private func needsMatchingReview(_ candidate: MovieFolderCandidate, saved record: FolderProcessingCacheRecord) -> Bool {
    guard record.status == .unresolved, record.savedMatchingRulesVersion != Self.savedMatchingRulesVersion,
      record.matchedMovieID == .none, record.movieIdentitySource != .explicitSelection,
      record.processingReason == .noSuitableMovie || record.processingReason == .ambiguousMovie,
      case .parsed(let parsed) = parser.parse(candidate.name) else { return false }

    return parsed.year != .none
  }

  /// Version of the completed conservative title and provider-year matching rules.
  static var savedMatchingRulesVersion: Int { 1 }

  /// Runs one fresh attempt and reports whether provider backoff must end the visit.
  func processCandidate(
    _ candidate: MovieFolderCandidate, root: URL, access: PersistenceAccess, visit: inout AutomaticProcessingPass
  ) async throws -> Bool {
    visit.activityLog?.begin(candidate.name, stage: .parse)
    visit.processingSummary.examined += 1
    var attempt = FolderPosterAssignmentAttemptResult()
    attempt.matchedMovie = savedActivityMovie(visit.processingCache.folders[candidate.name], candidate: candidate)
    do {
      try await matchAndAssignPoster(candidate, root: root, access: access, visit: &visit, attempt: &attempt)
    } catch let error as CollectionProcessingError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as ProcessingRecoveryError {
      guard try validateSelectedCandidate(candidate, root: root, visit: &visit) else { return false }

      return try recordRecoveryAdmissionFailure(
        error, candidate: candidate, access: access, visit: &visit, attempt: attempt)
    } catch let error as TMDbError {
      guard try validateSelectedCandidate(candidate, root: root, visit: &visit) else { return false }

      return try recordProviderFailure(error, candidate: candidate, access: access, visit: &visit, attempt: attempt)
    } catch {
      if Task.isCancelled { throw CancellationError() }

      guard try validateSelectedCandidate(candidate, root: root, visit: &visit) else { return false }

      recordTransientFailure(candidate, in: &visit.processingCache, stage: attempt.failedProcessingStage, movie: attempt.matchedMovie,
        releaseDates: attempt.acceptedMovieReleaseDates)
      var record = failedFolderResult(candidate, stage: attempt.failedProcessingStage, movie: attempt.matchedMovie)
      record.movieIdentitySource = visit.processingCache.folders[candidate.name]?.movieIdentitySource
        ?? record.movieIdentitySource
      visit.activityLog?.append(record,
        failure: MovieFolderActivityLogEvent.failureEvidence(for: error, stage: attempt.failedProcessingStage, occurredAt: now()))
      try saveState(visit.processingCache, to: access, activity: visit.activityLog)
      visit.processingSummary.transientFailures += 1
      try recordFolderProcessing(record, in: &visit.collectionProcessingRecord, activity: visit.activityLog)
    }

    return false
  }

  /// Retains the explicit admission reason without converting paused work into an ordinary retry.
  func recordRecoveryAdmissionFailure(
    _ error: ProcessingRecoveryError, candidate: MovieFolderCandidate, access: PersistenceAccess,
    visit: inout AutomaticProcessingPass, attempt: FolderPosterAssignmentAttemptResult,
    identitySource: MovieIdentitySource? = .none
  ) throws -> Bool {
    let reason: FolderProcessingReason
    let retryAt: Date?
    let failure: FolderProcessingFailureReason
    switch error {
    case .providerBackoff(let until, let category):
      reason = category
      retryAt = until
      failure = switch category {
      case .rateLimited: .rateLimited
      case .connectivity: .connectivity
      case .serverFailure: .serverFailure
      case .invalidResponse: .invalidResponse
      default: .unavailable
      }
    case .authenticationRequired:
      reason = .authentication
      retryAt = .none
      failure = .authentication
    default:
      throw error
    }

    recordTransientFailure(candidate, in: &visit.processingCache, stage: attempt.failedProcessingStage, movie: attempt.matchedMovie,
      reason: reason, failureReason: failure, releaseDates: attempt.acceptedMovieReleaseDates)
    if let identitySource { visit.processingCache.folders[candidate.name]?.movieIdentitySource = identitySource }
    visit.processingCache.folders[candidate.name]?.retryDate = retryAt
    var record = failedFolderResult(candidate, stage: attempt.failedProcessingStage, movie: attempt.matchedMovie,
      reason: reason, failureReason: failure)
    record.nextRetryAt = retryAt
    record.movieIdentitySource = identitySource
      ?? visit.processingCache.folders[candidate.name]?.movieIdentitySource ?? record.movieIdentitySource
    visit.activityLog?.append(record)
    try saveState(visit.processingCache, to: access, activity: visit.activityLog)
    try recordFolderProcessing(record, in: &visit.collectionProcessingRecord, activity: visit.activityLog)

    visit.processingSummary.providerRetryAt = retryAt
    if let retryAt {
      deferPendingFolderResults(
        &visit.collectionProcessingRecord, until: retryAt, child: visit.selectedRetryChildName, activity: visit.activityLog)
    }

    return true
  }

  /// Saves typed provider evidence and any root-local delay before ending the current attempt.
  func recordProviderFailure(
    _ error: TMDbError, candidate: MovieFolderCandidate, access: PersistenceAccess,
    visit: inout AutomaticProcessingPass, attempt: FolderPosterAssignmentAttemptResult,
    identitySource: MovieIdentitySource? = .none
  ) throws -> Bool {
    if Task.isCancelled { throw CancellationError() }

    let evidence = providerFailureEvidence(error, stage: attempt.failedProcessingStage)
    recordTransientFailure(
      candidate, in: &visit.processingCache, stage: attempt.failedProcessingStage, movie: attempt.matchedMovie,
      reason: evidence.reason, failureReason: evidence.failureReason, releaseDates: attempt.acceptedMovieReleaseDates)
    if let identitySource { visit.processingCache.folders[candidate.name]?.movieIdentitySource = identitySource }

    if let retryDate = try effectiveRootBackoff(for: error) {
      visit.processingCache.providerRetryAt = retryDate
      visit.processingCache.folders[candidate.name]?.retryDate = retryDate
      var record = failedFolderResult(
        candidate, stage: attempt.failedProcessingStage, movie: attempt.matchedMovie,
        reason: evidence.reason, failureReason: evidence.failureReason)
      record.nextRetryAt = retryDate
      record.movieIdentitySource = identitySource
      ?? visit.processingCache.folders[candidate.name]?.movieIdentitySource ?? record.movieIdentitySource
      visit.activityLog?.append(record)
      try saveState(visit.processingCache, to: access, activity: visit.activityLog)
      visit.processingSummary.providerRetryAt = retryDate
      try recordFolderProcessing(record, in: &visit.collectionProcessingRecord, activity: visit.activityLog)

      deferPendingFolderResults(
        &visit.collectionProcessingRecord, until: retryDate, child: visit.selectedRetryChildName, activity: visit.activityLog)
      return true
    }

    var record = failedFolderResult(
      candidate, stage: attempt.failedProcessingStage, movie: attempt.matchedMovie,
      reason: evidence.reason, failureReason: evidence.failureReason)
    record.movieIdentitySource = identitySource
      ?? visit.processingCache.folders[candidate.name]?.movieIdentitySource ?? record.movieIdentitySource
    visit.activityLog?.append(record)
    try saveState(visit.processingCache, to: access, activity: visit.activityLog)
    visit.processingSummary.transientFailures += 1
    try recordFolderProcessing(record, in: &visit.collectionProcessingRecord, activity: visit.activityLog)
    if evidence.reason == .authentication { return true }

    return false
  }

  /// Matches a member and assigns validated artwork in the original safety order.
  private func matchAndAssignPoster(
    _ candidate: MovieFolderCandidate, root: URL, access: PersistenceAccess,
    visit: inout AutomaticProcessingPass, attempt: inout FolderPosterAssignmentAttemptResult
  ) async throws {
    guard case .parsed(let parsed) = parser.parse(candidate.name) else {
      try recordUnresolvedAttempt(candidate, reason: .parsingProblem, access: access, visit: &visit)
      return
    }

    if movieMatchingConfiguration.requiresReleaseYearForAutomaticMatching, parsed.year == .none {
      try recordUnresolvedAttempt(candidate, reason: .manualMatchingRequired, access: access, visit: &visit)
      return
    }

    attempt.failedProcessingStage = .search
    visit.activityLog?.stage = .search

    guard let search = try await searchMovies(
      MovieSearchRequest(title: parsed.title, year: .none, candidate: candidate, root: root, access: access),
      visit: &visit)
    else { return }

    let identityResult = try await matchMovieUsingEvidence(title: parsed.title, year: parsed.year, search: search,
      state: &visit.processingCache)
    try Task.checkCancellation()

    guard try validateSelectedCandidate(candidate, root: root, visit: &visit) else { return }

    try saveState(visit.processingCache, to: access, activity: visit.activityLog)

    guard case .matched(let movie, let releaseDates) = identityResult, let posterPath = movie.posterPath,
      !posterPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      let (reason, identifiedMovie) = unresolvedIdentity(identityResult)
      try recordUnresolvedAttempt(candidate, reason: reason, movie: identifiedMovie,
        releaseDates: identityResult.acceptedMovieReleaseDates, access: access, visit: &visit)
      return
    }

    if let saved = visit.processingCache.folders[candidate.name], saved.fingerprint == candidate.fingerprint,
      let savedID = saved.matchedMovieID, savedID != movie.id {
      try recordUnresolvedAttempt(candidate, reason: .manualMatchingRequired, access: access, visit: &visit)
      return
    }

    let assignment = MatchedMovieFolderPosterAssignment(
      movie: movie, releaseDates: releaseDates, posterPath: posterPath,
      candidate: candidate, root: root, persistenceAccess: access)
    try await assignMatchedPoster(assignment, visit: &visit, attempt: &attempt)
  }

  /// Downloads and assigns artwork after the candidate's identity and poster path are confirmed.
  /// - Parameters:
  ///   - assignment: Confirmed movie, poster, and authorized folder context.
  ///   - visit: Processing state receiving cache and assignment results.
  ///   - attempt: Attempt evidence updated with the matched movie and stage.
  /// - Throws: Provider, cancellation, authorization, filesystem, or persistence errors.
  private func assignMatchedPoster(
    _ assignment: MatchedMovieFolderPosterAssignment, visit: inout AutomaticProcessingPass, attempt: inout FolderPosterAssignmentAttemptResult
  ) async throws {
    let movie = assignment.movie
    let candidate = assignment.candidate
    attempt.matchedMovie = movie
    attempt.acceptedMovieReleaseDates = savedReleaseDates(assignment.releaseDates, movie: movie, candidate: candidate,
      saved: visit.processingCache.folders[candidate.name]) ?? []
    visit.activityLog?.movie = movie
    attempt.failedProcessingStage = .artwork
    visit.activityLog?.stage = .artwork
    let imageData = try await posterBytes(for: assignment.posterPath, visit: &visit)

    guard try validateSelectedCandidate(candidate, root: assignment.root, visit: &visit) else { return }

    attempt.failedProcessingStage = .assignPoster
    visit.activityLog?.stage = .assignPoster
    let result = try assign(imageData, to: candidate, in: assignment.root)
    visit.activityLog?.append(result == .assigned ? .posterApplied : .preserved)

    var completedRecord = FolderProcessingCacheRecord(
      fingerprint: candidate.fingerprint,
      status: .processed,
      retryDate: .none,
      matchedMovieID: movie.id,
      posterPath: assignment.posterPath,
      movieTitle: movie.title,
      movieYear: movie.releaseYear,
      movieIdentitySource: .conservativeMatch
    )
    completedRecord.acceptedMovieReleaseDates = attempt.acceptedMovieReleaseDates
    completedRecord.savedMatchingRulesVersion = Self.savedMatchingRulesVersion
    completedRecord.nameParserRevision = ReleaseNameParser.revision
    visit.processingCache.folders[candidate.name] = completedRecord

    try saveAssignedState(
      visit.processingCache, to: assignment.persistenceAccess, candidate: candidate, root: assignment.root,
      processingState: &visit.collectionProcessingRecord, activity: visit.activityLog)
    if case .assigned = result { visit.processingSummary.assigned += 1 }
  }

  /// Persists one unresolved attempt in the operational cache and authoritative result projection.
  /// - Parameters:
  ///   - candidate: Current immediate-child identity and fingerprint.
  ///   - reason: Conservative classification established by parsing or matching.
  ///   - movie: Identified movie evidence, when artwork alone prevents assignment.
  ///   - access: Retained root cache access.
  ///   - visit: Visit receiving the cache, summary, and authoritative folder result.
  /// - Throws: Cache or authoritative-result persistence failures.
  private func recordUnresolvedAttempt(
    _ candidate: MovieFolderCandidate, reason: FolderProcessingReason, movie: MovieMetadata? = .none,
    releaseDates: [MovieReleaseDate] = [], access: PersistenceAccess, visit: inout AutomaticProcessingPass
  ) throws {
    recordUnresolved(candidate, in: &visit.processingCache, reason: reason, movie: movie, releaseDates: releaseDates)
    var record = unresolvedFolderResult(candidate, reason: reason, movie: movie)
    if let retained = visit.processingCache.folders[candidate.name], retained.matchedMovieID != .none {
      record = cachedFolderResult(candidate, saved: retained)
    }
    record.nextRetryAt = visit.processingCache.folders[candidate.name]?.retryDate
    visit.activityLog?.append(record)
    try saveState(visit.processingCache, to: access, activity: visit.activityLog)
    visit.processingSummary.unresolved += 1
    try recordFolderProcessing(record, in: &visit.collectionProcessingRecord, activity: visit.activityLog)
  }

  /// Retains the conservative unresolved reason and any identified movie.
  func unresolvedIdentity(_ identityResult: MovieMatchResult) -> (FolderProcessingReason, MovieMetadata?) {
    let reason: FolderProcessingReason
    let identifiedMovie: MovieMetadata?
    switch identityResult {
    case .matched(let movie, _):
      reason = .missingArtwork
      identifiedMovie = movie
    case .unresolved(let issue):
      identifiedMovie = .none
      switch issue {
      case .ambiguous: reason = .ambiguousMovie
      case .noSuitableMatch: reason = .noSuitableMovie
      case .incompleteSearch: reason = .incompleteSearch
      case .missingPoster: reason = .missingArtwork
      case .invalidQuery: reason = .parsingProblem
      case .incompleteYearEvidence, .incompleteTitleEvidence: reason = .manualMatchingRequired
      }
    }

    return (reason, identifiedMovie)
  }

  /// Reuses a current search or checkpoints a fresh response before further work.
  private func searchMovies(
    _ request: MovieSearchRequest, visit: inout AutomaticProcessingPass
  ) async throws -> MovieSearchResult? {
    let title = request.title
    let year = request.year
    let candidate = request.candidate
    let root = request.root
    let access = request.access
    let queryKey = try Self.queryKey(title: title, year: year,
      language: movieMatchingConfiguration.searchLanguage, credentialRevision: credentialRevision,
      usesFixtures: usesFixtureMetadata)
    if let cached = visit.processingCache.queries[queryKey],
      now().timeIntervalSince(cached.createdAt) < configuration.queryCacheLifetime {
      return cached.searchResult()
    } else {
      let search = try await provider.searchMovies(title: title, year: year,
        language: movieMatchingConfiguration.searchLanguage)
      try Task.checkCancellation()

      guard try validateSelectedCandidate(candidate, root: root, visit: &visit) else { return .none }

      visit.processingCache.queries[queryKey] = CachedMovieSearch(result: search, createdAt: now())
      try saveState(visit.processingCache, to: access, activity: visit.activityLog)

      return search
    }
  }

  /// Rechecks selected admission and identity before an awaited response can persist decisions.
  func validateSelectedCandidate(
    _ candidate: MovieFolderCandidate, root: URL, visit: inout AutomaticProcessingPass
  ) throws -> Bool {
    guard visit.selectedRetryChildName != .none else { return true }

    try Task.checkCancellation()
    try recovery?.validateProcessingAllowed()
    let settingsAccess = try checkIconChange(.automaticPosterAssignment, to: candidate, in: root)
    defer { withExtendedLifetime(settingsAccess) {} }
    let currentCandidate = try actionCandidate(root: root, child: candidate.name, expectedIdentity: candidate.identity)
    let currentFolderResult = try folderProcessingResult(
      currentCandidate, root: root, saved: visit.processingCache.folders[currentCandidate.name])

    guard !currentCandidate.hasCustomIcon, currentFolderResult.processingState != .suppressed,
      currentFolderResult.processingState != .preserved else {
      visit.activityLog?.append(currentFolderResult)
      try recordFolderProcessing(currentFolderResult, in: &visit.collectionProcessingRecord, activity: visit.activityLog)
      return false
    }

    return true
  }
}

/// The validated identity and access needed by one metadata search.
private struct MovieSearchRequest {
  /// Parsed title searched through the metadata provider.
  let title: String
  /// Parsed release year used to narrow the provider query.
  let year: Int?
  /// Folder whose identity is revalidated after the provider returns.
  let candidate: MovieFolderCandidate
  /// Authorized collection root containing the candidate.
  let root: URL
  /// Held root access protecting the operational cache.
  let access: PersistenceAccess
}

/// Mutable values owned by one automatic traversal, never shared between actor calls.
struct AutomaticProcessingPass {
  /// Operational decisions and query cache, loaded after inventory completes.
  var processingCache = CollectionProcessingCache()
  /// Authoritative result document checkpointed throughout the visit.
  var collectionProcessingRecord: CollectionProcessingState?
  /// Operation-local terminal events, never shared between actor calls.
  var activityLog: ProcessorActivityLog? = .none
  /// Counts reported to the caller independently of durable outcomes.
  var processingSummary = ProcessingSummary()
  /// Whether provider admission ended this traversal without a normal collection-wide completion.
  var providerAdmissionStoppedPass = false
  /// Limits each provider poster path to one download attempt during this traversal.
  var attemptedPosterImagePaths = Set<String>()
  /// Restricts result deferral and interruption to one member for an explicit retry.
  var selectedRetryChildName: String? = .none
}

/// Evidence retained as a fresh attempt advances across suspension points.
struct FolderPosterAssignmentAttemptResult {
  /// The stage used when reporting a failed operation.
  var failedProcessingStage: FolderProcessingStage = .parse
  /// The established movie identity, if matching succeeded.
  var matchedMovie: MovieMetadata?
  /// Dated provider provenance retained after matching even if artwork or assignment fails.
  var acceptedMovieReleaseDates: [MovieReleaseDate] = []
}

/// Cached decision and artwork reused without repeating a metadata request.
struct SavedFolderPosterAssignment {
  /// Validated cached source artwork.
  let bytes: Data
  /// Saved provider identity.
  let movieID: Int
  /// Saved provider-relative artwork path.
  let posterPath: String
  /// Saved title and identity provenance.
  let record: FolderProcessingCacheRecord
}

/// Confirmed movie and authorized folder context for one poster assignment.
private struct MatchedMovieFolderPosterAssignment {
  /// Movie matched under the current conservative rules.
  let movie: MovieMetadata
  /// Accepted provider release dates for the candidate's year.
  let releaseDates: [MovieReleaseDate]
  /// Provider-relative image path for the matched movie.
  let posterPath: String
  /// Immediate child whose icon may be updated.
  let candidate: MovieFolderCandidate
  /// Authorized collection root containing the candidate.
  let root: URL
  /// Held persistence authority for the root.
  let persistenceAccess: PersistenceAccess
}
