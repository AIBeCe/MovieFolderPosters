import FileSystem
import Foundation
import MovieFolderParsing
import Network
import Persistence

extension MovieFolderProcessor {
  /// Reuses unchanged decisions and reports whether this member is already handled.
  func reuseCachedDecision(
    _ candidate: FolderCandidate, root: URL, access: PersistenceAccess, visit: inout AutomaticProcessingVisit
  ) async throws -> Bool {
    let priorRecord = visit.cache.folders[candidate.name]
    let sameFingerprint = priorRecord?.fingerprint == candidate.fingerprint

    if sameFingerprint, let record = priorRecord {
      // An existing owned icon is assessed separately. An absent icon needs a current-configuration decision.
      if record.requiresAutomaticReassessment == true { return false }

      let needsParserReassessment = needsParserReassessment(candidate, saved: record)

      if !needsParserReassessment,
        record.blocksAutomaticRecovery || (record.processingReason == .authentication && recovery == nil) {
        visit.summary.unresolved += 1
        try recordFolderProcessing(
          cachedFolderAssessment(candidate, saved: record), in: &visit.recording, activity: visit.activity)
        return true
      }

      let canReuseSavedArtwork = record.status == .processed ||
        (record.status == .transientFailure &&
          (record.lastFailure?.stage == .artwork || record.lastFailure?.stage == .assignPoster)
          && (record.retryDate ?? .distantPast) <= now()) ||
        (record.status == .transientFailure && record.matchedMovieID != .none && record.posterPath != .none
          && record.lastFailure == .none && record.processingReason == .none)

      if canReuseSavedArtwork, let movieID = record.matchedMovieID, let posterPath = record.posterPath {
        let assignment: CachedPosterAssignment
        switch cachedPoster(for: posterPath) {
        case .valid(let bytes):
          assignment = CachedPosterAssignment(bytes: bytes, movieID: movieID, posterPath: posterPath, record: record)
        case .missing, .invalid:
          let decision = SavedPosterDecision(movieID: movieID, posterPath: posterPath, record: record)
          let context = ArtworkRepairContext(candidate: candidate, root: root, access: access)
          return try await repairCachedPoster(
            decision, context: context, visit: &visit)
        }

        try assignCachedPoster(assignment, candidate: candidate, root: root, access: access, visit: &visit)
        return true
      }

      if record.status != .processed, !record.needsLegacyReassessment, !needsParserReassessment,
        record.processingReason != .interrupted, let retryDate = record.retryDate, retryDate > now() {
        visit.summary.skippedRetryWindow += 1
        visit.activity?.movie = savedActivityMovie(record, candidate: candidate)
        visit.activity?.append(.deferred, reason: .retryDeferred, retryAt: record.retryDate)
        try recordFolderProcessing(
          cachedFolderAssessment(candidate, saved: record), in: &visit.recording, activity: visit.activity)
        return true
      }

      if record.needsLegacyReassessment || record.processingReason == .incompleteSearch || needsParserReassessment,
        case .parsed(let parsed) = parser.parse(candidate.name) {
        // A retry must not establish a new classification from the same inconclusive search.
        visit.cache.queries.removeValue(forKey: try Self.queryKey(title: parsed.title, year: parsed.year,
          language: movieMatchingConfiguration.searchLanguage, credentialRevision: credentialRevision,
          usesFixtures: usesFixtureMetadata))
        visit.cache.folders[candidate.name] = FolderRecord(
          fingerprint: candidate.fingerprint, status: .transientFailure, retryDate: .none,
          matchedMovieID: record.matchedMovieID, posterPath: record.posterPath, processingReason: .interrupted,
          movieTitle: record.movieTitle, movieYear: record.movieYear, movieIdentitySource: record.movieIdentitySource)
        try saveState(visit.cache, to: access, activity: visit.activity)
      }
    }

    return false
  }

  /// Detects an unchanged unresolved name whose parser revision permits fresh classification.
  /// - Parameters:
  ///   - candidate: Current folder identity and name.
  ///   - record: Saved unresolved decision for that folder.
  /// - Returns: Whether the saved decision needs parser reassessment.
  private func needsParserReassessment(_ candidate: FolderCandidate, saved record: FolderRecord) -> Bool {
    record.status == .unresolved
      && record.nameParserRevision != ReleaseNameParser.revision
      && (record.processingReason == .parsingProblem || record.processingReason == .noSuitableMovie
        || record.processingReason == .ambiguousMovie)
      && parser.hasRecognizedDatabaseIdentifierSuffix(candidate.name)
  }

  /// Runs one fresh attempt and reports whether provider backoff must end the visit.
  func processCandidate(
    _ candidate: FolderCandidate, root: URL, access: PersistenceAccess, visit: inout AutomaticProcessingVisit
  ) async throws -> Bool {
    visit.activity?.begin(candidate.name, stage: .parse)
    visit.summary.examined += 1
    var attempt = PosterAttempt()
    attempt.movie = savedActivityMovie(visit.cache.folders[candidate.name], candidate: candidate)
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

      recordTransientFailure(candidate, in: &visit.cache, stage: attempt.stage, movie: attempt.movie)
      var record = failedFolderAssessment(candidate, stage: attempt.stage, movie: attempt.movie)
      record.movieIdentitySource = visit.cache.folders[candidate.name]?.movieIdentitySource
        ?? record.movieIdentitySource
      visit.activity?.append(record,
        failure: MovieFolderActivityLogEvent.failureEvidence(for: error, stage: attempt.stage, occurredAt: now()))
      try saveState(visit.cache, to: access, activity: visit.activity)
      visit.summary.transientFailures += 1
      try recordFolderProcessing(record, in: &visit.recording, activity: visit.activity)
    }

    return false
  }

  /// Retains the explicit admission reason without converting paused work into an ordinary retry.
  func recordRecoveryAdmissionFailure(
    _ error: ProcessingRecoveryError, candidate: FolderCandidate, access: PersistenceAccess,
    visit: inout AutomaticProcessingVisit, attempt: PosterAttempt,
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

    recordTransientFailure(candidate, in: &visit.cache, stage: attempt.stage, movie: attempt.movie,
      reason: reason, failureReason: failure)
    if let identitySource { visit.cache.folders[candidate.name]?.movieIdentitySource = identitySource }
    visit.cache.folders[candidate.name]?.retryDate = retryAt
    var record = failedFolderAssessment(candidate, stage: attempt.stage, movie: attempt.movie,
      reason: reason, failureReason: failure)
    record.retryAt = retryAt
    record.movieIdentitySource = identitySource
      ?? visit.cache.folders[candidate.name]?.movieIdentitySource ?? record.movieIdentitySource
    visit.activity?.append(record)
    try saveState(visit.cache, to: access, activity: visit.activity)
    try recordFolderProcessing(record, in: &visit.recording, activity: visit.activity)

    visit.summary.providerRetryAt = retryAt
    if let retryAt {
      deferPendingFolderAssessments(
        &visit.recording, until: retryAt, child: visit.selectedChild, activity: visit.activity)
    }

    return true
  }

  /// Saves typed provider evidence and any root-local delay before ending the current attempt.
  func recordProviderFailure(
    _ error: TMDbError, candidate: FolderCandidate, access: PersistenceAccess,
    visit: inout AutomaticProcessingVisit, attempt: PosterAttempt,
    identitySource: MovieIdentitySource? = .none
  ) throws -> Bool {
    if Task.isCancelled { throw CancellationError() }

    let evidence = providerFailureEvidence(error, stage: attempt.stage)
    recordTransientFailure(
      candidate, in: &visit.cache, stage: attempt.stage, movie: attempt.movie,
      reason: evidence.reason, failureReason: evidence.failureReason)
    if let identitySource { visit.cache.folders[candidate.name]?.movieIdentitySource = identitySource }

    if let retryDate = try effectiveRootBackoff(for: error) {
      visit.cache.providerRetryAt = retryDate
      visit.cache.folders[candidate.name]?.retryDate = retryDate
      var record = failedFolderAssessment(
        candidate, stage: attempt.stage, movie: attempt.movie,
        reason: evidence.reason, failureReason: evidence.failureReason)
      record.retryAt = retryDate
      record.movieIdentitySource = identitySource
      ?? visit.cache.folders[candidate.name]?.movieIdentitySource ?? record.movieIdentitySource
      visit.activity?.append(record)
      try saveState(visit.cache, to: access, activity: visit.activity)
      visit.summary.providerRetryAt = retryDate
      try recordFolderProcessing(record, in: &visit.recording, activity: visit.activity)

      deferPendingFolderAssessments(
        &visit.recording, until: retryDate, child: visit.selectedChild, activity: visit.activity)
      return true
    }

    var record = failedFolderAssessment(
      candidate, stage: attempt.stage, movie: attempt.movie,
      reason: evidence.reason, failureReason: evidence.failureReason)
    record.movieIdentitySource = identitySource
      ?? visit.cache.folders[candidate.name]?.movieIdentitySource ?? record.movieIdentitySource
    visit.activity?.append(record)
    try saveState(visit.cache, to: access, activity: visit.activity)
    visit.summary.transientFailures += 1
    try recordFolderProcessing(record, in: &visit.recording, activity: visit.activity)
    if evidence.reason == .authentication { return true }

    return false
  }

  /// Matches a member and assigns validated artwork in the original safety order.
  private func matchAndAssignPoster(
    _ candidate: FolderCandidate, root: URL, access: PersistenceAccess,
    visit: inout AutomaticProcessingVisit, attempt: inout PosterAttempt
  ) async throws {
    guard case .parsed(let parsed) = parser.parse(candidate.name) else {
      try recordUnresolvedAttempt(candidate, reason: .parsingProblem, access: access, visit: &visit)
      return
    }

    if movieMatchingConfiguration.requiresReleaseYearForAutomaticMatching, parsed.year == .none {
      try recordUnresolvedAttempt(candidate, reason: .manualMatchingRequired, access: access, visit: &visit)
      return
    }

    attempt.stage = .search
    visit.activity?.stage = .search

    guard let search = try await searchMovies(
      MovieSearchRequest(title: parsed.title, year: parsed.year, candidate: candidate, root: root, access: access),
      visit: &visit)
    else { return }

    let identityResult = try await assessMovie(title: parsed.title, year: parsed.year, search: search,
      state: &visit.cache)
    try Task.checkCancellation()

    guard try validateSelectedCandidate(candidate, root: root, visit: &visit) else { return }

    try saveState(visit.cache, to: access, activity: visit.activity)

    guard case .matched(let movie) = identityResult, let posterPath = movie.posterPath,
      !posterPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      let (reason, identifiedMovie) = unresolvedIdentity(identityResult)
      try recordUnresolvedAttempt(candidate, reason: reason, movie: identifiedMovie, access: access, visit: &visit)
      return
    }

    if let saved = visit.cache.folders[candidate.name], saved.fingerprint == candidate.fingerprint,
      let savedID = saved.matchedMovieID, savedID != movie.id {
      try recordUnresolvedAttempt(candidate, reason: .manualMatchingRequired, access: access, visit: &visit)
      return
    }

    attempt.movie = movie
    visit.activity?.movie = movie
    attempt.stage = .artwork
    visit.activity?.stage = .artwork
    let imageData = try await posterBytes(for: posterPath, visit: &visit)

    guard try validateSelectedCandidate(candidate, root: root, visit: &visit) else { return }

    attempt.stage = .assignPoster
    visit.activity?.stage = .assignPoster
    let result = try assign(imageData, to: candidate, in: root)
    visit.activity?.append(result == .assigned ? .posterApplied : .preserved)

    var completedRecord = FolderRecord(
      fingerprint: candidate.fingerprint,
      status: .processed,
      retryDate: .none,
      matchedMovieID: movie.id,
      posterPath: posterPath,
      movieTitle: movie.title,
      movieYear: movie.releaseYear,
      movieIdentitySource: .conservativeMatch
    )
    completedRecord.nameParserRevision = ReleaseNameParser.revision
    visit.cache.folders[candidate.name] = completedRecord

    try saveAssignedState(
      visit.cache, to: access, candidate: candidate, root: root,
      processingState: &visit.recording, activity: visit.activity)
    if case .assigned = result { visit.summary.assigned += 1 }
  }

  /// Persists one unresolved attempt in the operational cache and authoritative result projection.
  /// - Parameters:
  ///   - candidate: Current immediate-child identity and fingerprint.
  ///   - reason: Conservative classification established by parsing or matching.
  ///   - movie: Identified movie evidence, when artwork alone prevents assignment.
  ///   - access: Retained root cache access.
  ///   - visit: Visit receiving the cache, summary, and authoritative assessment.
  /// - Throws: Cache or authoritative-result persistence failures.
  private func recordUnresolvedAttempt(
    _ candidate: FolderCandidate, reason: FolderProcessingReason, movie: MovieMetadata? = .none,
    access: PersistenceAccess, visit: inout AutomaticProcessingVisit
  ) throws {
    recordUnresolved(candidate, in: &visit.cache, reason: reason, movie: movie)
    var record = unresolvedFolderAssessment(candidate, reason: reason, movie: movie)
    if let retained = visit.cache.folders[candidate.name], retained.matchedMovieID != .none {
      record = cachedFolderAssessment(candidate, saved: retained)
    }
    record.retryAt = visit.cache.folders[candidate.name]?.retryDate
    visit.activity?.append(record)
    try saveState(visit.cache, to: access, activity: visit.activity)
    visit.summary.unresolved += 1
    try recordFolderProcessing(record, in: &visit.recording, activity: visit.activity)
  }

  /// Retains the conservative unresolved reason and any identified movie.
  func unresolvedIdentity(_ identityResult: MovieMatchResult) -> (FolderProcessingReason, MovieMetadata?) {
    let reason: FolderProcessingReason
    let identifiedMovie: MovieMetadata?
    switch identityResult {
    case .matched(let movie):
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
      case .incompleteTitleEvidence: reason = .manualMatchingRequired
      }
    }

    return (reason, identifiedMovie)
  }

  /// Reuses a current search or checkpoints a fresh response before further work.
  private func searchMovies(
    _ request: MovieSearchRequest, visit: inout AutomaticProcessingVisit
  ) async throws -> MovieSearchResult? {
    let title = request.title
    let year = request.year
    let candidate = request.candidate
    let root = request.root
    let access = request.access
    let queryKey = try Self.queryKey(title: title, year: year,
      language: movieMatchingConfiguration.searchLanguage, credentialRevision: credentialRevision,
      usesFixtures: usesFixtureMetadata)
    if let cached = visit.cache.queries[queryKey],
      now().timeIntervalSince(cached.createdAt) < configuration.queryCacheLifetime {
      return cached.searchResult()
    } else {
      let search = try await provider.searchMovies(title: title, year: year,
        language: movieMatchingConfiguration.searchLanguage)
      try Task.checkCancellation()

      guard try validateSelectedCandidate(candidate, root: root, visit: &visit) else { return .none }

      visit.cache.queries[queryKey] = CachedSearch(result: search, createdAt: now())
      try saveState(visit.cache, to: access, activity: visit.activity)

      return search
    }
  }

  /// Rechecks selected admission and identity before an awaited response can persist decisions.
  func validateSelectedCandidate(
    _ candidate: FolderCandidate, root: URL, visit: inout AutomaticProcessingVisit
  ) throws -> Bool {
    guard visit.selectedChild != .none else { return true }

    try Task.checkCancellation()
    try recovery?.validateProcessingAllowed()
    let settingsAccess = try checkIconChange(.automaticPosterAssignment, to: candidate, in: root)
    defer { withExtendedLifetime(settingsAccess) {} }
    let currentCandidate = try actionCandidate(root: root, child: candidate.name, expectedIdentity: candidate.identity)
    let currentAssessment = try assessFolderProcessing(
      currentCandidate, root: root, saved: visit.cache.folders[currentCandidate.name])

    guard !currentCandidate.hasCustomIcon, currentAssessment.state != .suppressed,
      currentAssessment.state != .preserved else {
      visit.activity?.append(currentAssessment)
      try recordFolderProcessing(currentAssessment, in: &visit.recording, activity: visit.activity)
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
  let candidate: FolderCandidate
  /// Authorized collection root containing the candidate.
  let root: URL
  /// Held root access protecting the operational cache.
  let access: PersistenceAccess
}

/// Mutable values owned by one automatic traversal, never shared between actor calls.
struct AutomaticProcessingVisit {
  /// Operational decisions and query cache, loaded after inventory completes.
  var cache = ProcessingState()
  /// Authoritative result document checkpointed throughout the visit.
  var recording: CollectionProcessingState?
  /// Operation-local terminal events, never shared between actor calls.
  var activity: ProcessorActivityLog? = .none
  /// Counts reported to the caller independently of durable outcomes.
  var summary = ProcessingSummary()
  /// Whether provider admission ended this traversal without a normal collection-wide completion.
  var didStopEarly = false
  /// Limits each provider poster path to one download attempt during this traversal.
  var attemptedPosterPaths = Set<String>()
  /// Restricts result deferral and interruption to one member for an explicit retry.
  var selectedChild: String? = .none
}

/// Evidence retained as a fresh attempt advances across suspension points.
struct PosterAttempt {
  /// The stage used when reporting a failed operation.
  var stage: FolderProcessingStage = .parse
  /// The established movie identity, if matching succeeded.
  var movie: MovieMetadata?
}

/// Cached decision and artwork reused without repeating a metadata request.
struct CachedPosterAssignment {
  /// Validated cached source artwork.
  let bytes: Data
  /// Saved provider identity.
  let movieID: Int
  /// Saved provider-relative artwork path.
  let posterPath: String
  /// Saved title and identity provenance.
  let record: FolderRecord
}
