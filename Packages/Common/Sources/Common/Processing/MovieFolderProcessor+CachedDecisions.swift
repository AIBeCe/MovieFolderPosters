import FileSystem
import Foundation
import MovieFolderParsing
import Persistence

extension MovieFolderProcessor {
  /// Reuses unchanged decisions and reports whether this member is already handled.
  func reuseCachedDecision(
    _ candidate: MovieFolderCandidate,
    root: URL,
    access: PersistenceAccess,
    visit: inout AutomaticProcessingPass
  ) async throws -> Bool {
    if visit.localInformationReadResults[candidate.name] == nil {
      try prepareMovieInformation(candidate, root: root, visit: &visit)
    }
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
          cachedFolderResult(candidate, saved: record), in: &visit.collectionProcessingRecord,
            activity: visit.activityLog)
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
          assignment = SavedFolderPosterAssignment(bytes: bytes, movieID: movieID,
            posterPath: posterPath, record: record)
        case .missing, .invalid:
          let decision = SavedPosterDecision(movieID: movieID, posterPath: posterPath, record: record)
          let context = ArtworkRepairContext(candidate: candidate, root: root, access: access)
          return try await repairCachedPoster(
            decision, context: context, visit: &visit)
        }

        try await assignCachedPoster(assignment, candidate: candidate, root: root, access: access, visit: &visit)
        return true
      }

      if try shouldDeferCachedRetry(candidate, saved: record, needsParserReview: needsParserReview,
        needsMatchingReview: needsMatchingReview, visit: &visit) { return true }

      try invalidateInconclusiveCachedDecision(
        candidate, record: record, review: needsParserReview || needsMatchingReview,
        access: access, visit: &visit)
    }

    return false
  }

  /// Invalidates the saved query and decision when current rules require an inconclusive result to be retried.
  private func invalidateInconclusiveCachedDecision(
    _ candidate: MovieFolderCandidate,
    record: FolderProcessingCacheRecord,
    review: Bool,
    access: PersistenceAccess,
    visit: inout AutomaticProcessingPass
  ) throws {
    guard record.isLegacyUnresolvedResult || record.processingReason == .incompleteSearch || review,
      case .parsed(let parsed) = parser.parse(candidate.name)
    else { return }

    let queryKey = try Self.queryKey(
      title: parsed.title,
      year: .none,
      language: movieMatchingConfiguration.searchLanguage,
      credentialRevision: credentialRevision,
      usesStubTMDbResponses: usesStubTMDbResponses,
      pageLimit: searchPageLimit)
    visit.processingCache.queries.removeValue(forKey: queryKey)
    visit.processingCache.folders[candidate.name] = FolderProcessingCacheRecord(
      fingerprint: candidate.fingerprint,
      status: .transientFailure,
      retryDate: .none,
      matchedMovieID: record.matchedMovieID,
      posterPath: record.posterPath,
      processingReason: .interrupted,
      movieTitle: record.movieTitle,
      movieYear: record.movieYear,
      movieIdentitySource: record.movieIdentitySource)
    visit.processingCache.folders[candidate.name]?.localInformationReadResultSHA256 =
      record.localInformationReadResultSHA256
    try saveState(visit.processingCache, to: access, activity: visit.activityLog)
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
  private func needsMatchingReview(_ candidate: MovieFolderCandidate, saved record:
    FolderProcessingCacheRecord) -> Bool {
    guard record.status == .unresolved, (record.savedMatchingRulesVersion ?? 0) < 1,
      record.matchedMovieID == .none, record.movieIdentitySource != .explicitSelection,
      record.processingReason == .noSuitableMovie || record.processingReason == .ambiguousMovie,
      case .parsed(let parsed) = parser.parse(candidate.name) else { return false }

    return parsed.year != .none
  }
}
