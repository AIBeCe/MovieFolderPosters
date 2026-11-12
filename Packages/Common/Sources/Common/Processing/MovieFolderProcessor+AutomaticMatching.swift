import FileSystem
import Foundation
import MovieFolderParsing
import Persistence

extension MovieFolderProcessor {
  /// Version of the completed conservative title and provider-year matching rules.
  static var savedMatchingRulesVersion: Int { 2 }

  /// Runs one fresh attempt and reports whether provider backoff must end the visit.
  func processCandidate(
    _ candidate: MovieFolderCandidate, root: URL, access: PersistenceAccess, visit: inout AutomaticProcessingPass
  ) async throws -> Bool {
    visit.activityLog?.begin(candidate.name, stage: .parse)
    visit.processingSummary.examined += 1
    if visit.processingCache.folders[candidate.name]?.provisionalCorrectedMatch == true {
      visit.processingCache.folders.removeValue(forKey: candidate.name)
    }
    var attempt = FolderPosterAssignmentAttemptResult()
    attempt.searchCorrection = visit.searchCorrection
    attempt.localInformationReadResultSHA256 = visit.localInformationReadResults[candidate.name]?.sha256
    let saved = visit.processingCache.folders[candidate.name]
    attempt.protectsSavedIdentity = saved?.fingerprint == candidate.fingerprint && saved?.protectsMovieIdentity == true
    attempt.matchedMovie = savedActivityMovie(saved, candidate: candidate)
    do {
      try await matchAndAssignPoster(candidate, root: root, access: access, visit: &visit, attempt: &attempt)
    } catch let error where error is CollectionProcessingError || error is ConfigurationError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch AutomaticProcessingIssue.changedInformation {
      saveTemporaryFailure(candidate, in: &visit.processingCache, reason: .interrupted)
      visit.processingCache.folders[candidate.name]?.localInformationReadResultSHA256 =
        attempt.localInformationReadResultSHA256
      visit.recordCorrectionEvidence(
        for: candidate.name, correction: attempt.searchCorrection, protectsSavedIdentity: attempt.protectsSavedIdentity)
      try saveState(visit.processingCache, to: access, activity: visit.activityLog)
      visit.processingSummary.transientFailures += 1
      let record = failedFolderResult(candidate, stage: .search, reason: .interrupted)
      try recordFolderProcessing(record, in: &visit.collectionProcessingRecord, activity: visit.activityLog)
    } catch let error as ProcessingRecoveryError {
      guard try await validateSelectedCandidate(candidate, root: root, visit: &visit) else { return false }

      return try recordRecoveryAdmissionFailure(
        error, candidate: candidate, access: access, visit: &visit, attempt: attempt,
        identitySource: attempt.matchedMovie == .none ? .none : attempt.movieIdentitySource)
    } catch let error as MovieMetadataError {
      guard try await validateSelectedCandidate(candidate, root: root, visit: &visit) else { return false }

      return try recordSourceProviderFailure(
        error, candidate: candidate, access: access, visit: &visit, attempt: attempt,
        identitySource: attempt.matchedMovie == .none ? .none : attempt.movieIdentitySource)
    } catch {
      if Task.isCancelled { throw CancellationError() }

      guard try await validateSelectedCandidate(candidate, root: root, visit: &visit) else { return false }

      try recordUnexpectedProcessingFailure(
        error, candidate: candidate, access: access, visit: &visit, attempt: attempt)
    }

    return false
  }

  /// Checkpoints an unexpected failure after the caller has revalidated the selected folder.
  /// - Parameters:
  ///   - error: Failure retained in the attempt's activity log.
  ///   - candidate: Revalidated immediate child.
  ///   - access: Held access for persisting the root's processing cache.
  ///   - visit: Processing state that receives the failure and its authoritative projection.
  ///   - attempt: Stage, identity, and input digest from the failed attempt.
  /// - Throws: Processing cache or authoritative result persistence errors.
  private func recordUnexpectedProcessingFailure(
    _ error: any Error,
    candidate: MovieFolderCandidate,
    access: PersistenceAccess,
    visit: inout AutomaticProcessingPass,
    attempt: FolderPosterAssignmentAttemptResult
  ) throws {
    saveTemporaryFailure(candidate, in: &visit.processingCache, stage:
      attempt.failedProcessingStage, movie: attempt.matchedMovie,
      releaseDates: attempt.acceptedMovieReleaseDates)
    visit.processingCache.folders[candidate.name]?.localInformationReadResultSHA256 =
      attempt.localInformationReadResultSHA256
    visit.recordCorrectionEvidence(
      for: candidate.name, correction: attempt.searchCorrection, protectsSavedIdentity: attempt.protectsSavedIdentity)
    if attempt.matchedMovie != .none,
      visit.processingCache.folders[candidate.name]?.movieIdentitySource != .explicitSelection {
      visit.processingCache.folders[candidate.name]?.movieIdentitySource = attempt.movieIdentitySource
    }
    var record = failedFolderResult(candidate, stage: attempt.failedProcessingStage, movie: attempt.matchedMovie)
    record.movieIdentitySource = visit.processingCache.folders[candidate.name]?.movieIdentitySource
      ?? record.movieIdentitySource
    visit.activityLog?.append(record,
      failure: MovieFolderActivityLogEvent.failureEvidence(for: error, stage:
        attempt.failedProcessingStage, occurredAt: now()))
    try saveState(visit.processingCache, to: access, activity: visit.activityLog)
    visit.processingSummary.transientFailures += 1
    try recordFolderProcessing(record, in: &visit.collectionProcessingRecord, activity: visit.activityLog)
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

    saveTemporaryFailure(candidate, in: &visit.processingCache, stage:
      attempt.failedProcessingStage, movie: attempt.matchedMovie,
      reason: reason, failureReason: failure, releaseDates: attempt.acceptedMovieReleaseDates)
    visit.processingCache.folders[candidate.name]?.localInformationReadResultSHA256 =
      attempt.localInformationReadResultSHA256
    visit.recordCorrectionEvidence(
      for: candidate.name, correction: attempt.searchCorrection, protectsSavedIdentity: attempt.protectsSavedIdentity)
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
        &visit.collectionProcessingRecord, until: retryAt, child: visit.selectedRetryChildName,
          activity: visit.activityLog)
    }

    return true
  }

  /// Saves typed provider evidence and any root-local delay before ending the current attempt.
  func recordSourceProviderFailure(
    _ error: MovieMetadataError, candidate: MovieFolderCandidate, access: PersistenceAccess,
    visit: inout AutomaticProcessingPass, attempt: FolderPosterAssignmentAttemptResult,
    identitySource: MovieIdentitySource? = .none
  ) throws -> Bool {
    if Task.isCancelled { throw CancellationError() }

    let evidence = providerFailureEvidence(error, stage: attempt.failedProcessingStage)
    saveTemporaryFailure(
      candidate, in: &visit.processingCache, stage: attempt.failedProcessingStage, movie: attempt.matchedMovie,
      reason: evidence.reason, failureReason: evidence.failureReason, releaseDates: attempt.acceptedMovieReleaseDates)
    visit.processingCache.folders[candidate.name]?.localInformationReadResultSHA256 =
      attempt.localInformationReadResultSHA256
    visit.recordCorrectionEvidence(
      for: candidate.name, correction: attempt.searchCorrection, protectsSavedIdentity: attempt.protectsSavedIdentity)
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
        &visit.collectionProcessingRecord, until: retryDate, child:
          visit.selectedRetryChildName, activity: visit.activityLog)
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
    let (readResult, context) = try prepareMatchingInformation(candidate, root: root, visit: &visit, attempt: &attempt)
    let resolver = LocalMovieInformationResolver()
    let title: String
    let year: Int?
    let explicitIdentifiers: [MovieIdentifier]
    if let correction = context.searchCorrection?.captured.correction {
      switch resolver.resolve(folderName: candidate.name, readResult: readResult, correction: correction) {
      case .search(let fields, let identifiers):
        title = fields.title
        year = fields.year
        explicitIdentifiers = identifiers
        attempt.movieIdentitySource = .savedSearchCorrection
      case .conflicting:
        try recordUnresolvedAttempt(candidate, reason: .conflictingMovieInformation, access: access, visit: &visit)
        return
      case .unusable:
        try recordUnresolvedAttempt(candidate, reason: .manualMatchingRequired, access: access, visit: &visit)
        return
      }
    } else {
      explicitIdentifiers = []
      switch resolver.resolve(folderName: candidate.name, readResult: readResult) {
      case .title(let selectedTitle, let selectedYear, let source):
        title = selectedTitle
        year = selectedYear
        attempt.movieIdentitySource = source.identitySource
      case .unparseableFolder:
        try recordUnresolvedAttempt(candidate, reason: .parsingProblem, access: access, visit: &visit)
        return
      case .conflicting:
        try recordUnresolvedAttempt(candidate, reason: .conflictingMovieInformation, access: access, visit: &visit)
        return
      case .unusable:
        try recordUnresolvedAttempt(candidate, reason: .manualMatchingRequired, access: access, visit: &visit)
        return
      case .identifiers(let identifiers):
        try await matchAndAssignIdentifierPoster(identifiers, context: context, access: access,
          visit: &visit, attempt: &attempt)
        return
      }
    }

    visit.activityLog?.matchingDiagnostics = MovieMatchingDiagnostics(
      selectedTitle: title, selectedYear: year, source: attempt.movieIdentitySource)

    if movieMatchingConfiguration.requiresReleaseYearForAutomaticMatching, year == .none {
      try recordUnresolvedAttempt(candidate, reason: .manualMatchingRequired, access: access, visit: &visit)
      return
    }

    attempt.failedProcessingStage = .search
    visit.activityLog?.stage = .search

    guard let search = try await searchMovies(
      MovieSearchRequest(title: title, year: .none, candidate: candidate, root: root, access: access),
      visit: &visit)
    else { return }

    let identityResult = try await fetchAlternativeTitlesAndReleaseDates(title: title, year: year, search: search,
      state: &visit.processingCache, metadataProvider: informationProvider(context), activity: visit.activityLog)
    try Task.checkCancellation()

    guard try await validateSelectedCandidate(candidate, root: root, visit: &visit) else { return }

    try saveState(visit.processingCache, to: access, activity: visit.activityLog)

    guard case .matched(let movie, let releaseDates) = identityResult else {
      let (reason, identifiedMovie) = unresolvedIdentity(identityResult)
      try recordUnresolvedAttempt(candidate, reason: reason, movie: identifiedMovie,
        releaseDates: identityResult.acceptedMovieReleaseDates, identitySource: attempt.movieIdentitySource,
        access: access, visit: &visit)
      return
    }

    if !explicitIdentifiers.isEmpty {
      visit.activityLog?.matchingDiagnostics = visit.activityLog?.matchingDiagnostics?.recording(outcome: .notEvaluated)
      let resolution = try await informationProvider(context).resolveMovieIdentifiers(
        explicitIdentifiers, language: movieMatchingConfiguration.searchLanguage)

      switch resolution {
      case .matched(let identified) where identified.id == movie.id:
        visit.activityLog?.matchingDiagnostics = visit.activityLog?.matchingDiagnostics?.recording(outcome: .matched)
      case .matched, .conflicting:
        visit.activityLog?.matchingDiagnostics = visit.activityLog?.matchingDiagnostics?.recording(
          outcome: .identifierConflict)
        try recordUnresolvedAttempt(candidate, reason: .conflictingMovieInformation, access: access, visit: &visit)
        return
      case .notFound:
        visit.activityLog?.matchingDiagnostics = visit.activityLog?.matchingDiagnostics?.recording(
          outcome: .identifierNotFound)
        try recordUnresolvedAttempt(candidate, reason: .noSuitableMovie, access: access, visit: &visit)
        return
      }
    }

    guard let posterPath = movie.posterPath, !posterPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      try recordUnresolvedAttempt(candidate, reason: .missingArtwork, movie: movie,
        releaseDates: releaseDates, identitySource: attempt.movieIdentitySource, access: access, visit: &visit)
      return
    }

    let assignment = MatchedMovieFolderPosterAssignment(
      movie: movie, releaseDates: releaseDates, posterPath: posterPath,
      candidate: candidate, root: root, persistenceAccess: access)
    try await assignMatchedPoster(assignment, visit: &visit, attempt: &attempt)
  }

  /// Retains the initial input and freshness context for all metadata and assignment steps.
  /// - Parameters:
  ///   - candidate: Immediate child whose selected information will be interpreted.
  ///   - root: Authorized collection root.
  ///   - visit: Processing state that retains the bounded information read.
  ///   - attempt: Attempt receiving the digest of its initial inputs.
  /// - Returns: The bounded information and its matching freshness context.
  /// - Throws: Cancellation, changed directory identity, or local read errors.
  private func prepareMatchingInformation(
    _ candidate: MovieFolderCandidate,
    root: URL,
    visit: inout AutomaticProcessingPass,
    attempt: inout FolderPosterAssignmentAttemptResult
  ) throws -> (MovieFolderInformationReadResult, MovieInformationReadContext) {
    let readResult: MovieFolderInformationReadResult
    if let existing = visit.localInformationReadResults[candidate.name] {
      readResult = existing
    } else {
      readResult = try readMovieInformation(candidate, root: root)
      visit.localInformationReadResults = [candidate.name: readResult]
    }
    attempt.localInformationReadResultSHA256 = readResult.sha256
    let context = informationContext(
      candidate, root: root, sha256: readResult.sha256, searchCorrection: visit.searchCorrection)
    visit.localInformationContexts = [candidate.name: context]

    return (readResult, context)
  }

  /// Matches a validated provider identifier and assigns its artwork after rechecking the selected folder.
  /// - Parameters:
  ///   - identifiers: Reconciled identifiers supplied by the selected local information.
  ///   - context: Captured folder identity and local information digest.
  ///   - access: Held access for persisting this root's processing cache.
  ///   - visit: Processing state receiving the match or unresolved decision.
  ///   - attempt: Attempt receiving the identifier provenance and stage.
  /// - Throws: Provider, cancellation, authorization, filesystem, or persistence errors.
  private func matchAndAssignIdentifierPoster(
    _ identifiers: [MovieIdentifier],
    context: MovieInformationReadContext,
    access: PersistenceAccess,
    visit: inout AutomaticProcessingPass,
    attempt: inout FolderPosterAssignmentAttemptResult
  ) async throws {
    let candidate = context.candidate
    let root = context.root
    let metadataProvider = informationProvider(context)
    attempt.movieIdentitySource = .validatedIdentifier
    attempt.failedProcessingStage = .search
    visit.activityLog?.stage = .search
    visit.activityLog?.matchingDiagnostics = MovieMatchingDiagnostics(source: .validatedIdentifier)
    let resolution = try await metadataProvider.resolveMovieIdentifiers(identifiers,
      language: movieMatchingConfiguration.searchLanguage)
    try Task.checkCancellation()

    guard try await validateSelectedCandidate(candidate, root: root, visit: &visit) else { return }
    let movie: MovieMetadata
    switch resolution {
    case .matched(let resolved):
      movie = resolved
      visit.activityLog?.matchingDiagnostics = visit.activityLog?.matchingDiagnostics?.recording(
        candidates: [.init(movie: resolved, verdict: .identifierResolved)], outcome: .identifierMatched)
    case .conflicting:
      visit.activityLog?.matchingDiagnostics = visit.activityLog?.matchingDiagnostics?.recording(
        outcome: .identifierConflict)
      try recordUnresolvedAttempt(candidate, reason: .conflictingMovieInformation, access: access, visit: &visit)
      return
    case .notFound:
      visit.activityLog?.matchingDiagnostics = visit.activityLog?.matchingDiagnostics?.recording(
        outcome: .identifierNotFound)
      try recordUnresolvedAttempt(candidate, reason: .noSuitableMovie, access: access, visit: &visit)
      return
    }
    guard let posterPath = movie.posterPath,
      !posterPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      try recordUnresolvedAttempt(candidate, reason: .missingArtwork, movie: movie,
        identitySource: attempt.movieIdentitySource, access: access, visit: &visit)
      return
    }

    let assignment = MatchedMovieFolderPosterAssignment(movie: movie, releaseDates: [], posterPath: posterPath,
      candidate: candidate, root: root, persistenceAccess: access)
    try await assignMatchedPoster(assignment, visit: &visit, attempt: &attempt)
  }

  /// Rejects replacements of a saved identity before downloading and assigning matched artwork.
  /// - Parameters:
  ///   - assignment: Confirmed movie, poster, and authorized folder context.
  ///   - visit: Processing state receiving cache and assignment results.
  ///   - attempt: Attempt evidence updated with the matched movie and stage.
  /// - Throws: Provider, cancellation, authorization, filesystem, or persistence errors.
  private func assignMatchedPoster(
    _ assignment: MatchedMovieFolderPosterAssignment, visit: inout AutomaticProcessingPass,
    attempt: inout FolderPosterAssignmentAttemptResult
  ) async throws {
    let movie = assignment.movie
    let candidate = assignment.candidate
    if let saved = visit.processingCache.folders[candidate.name], saved.fingerprint == candidate.fingerprint,
      let savedID = saved.matchedMovieID, savedID != movie.id {
      try recordUnresolvedAttempt(candidate, reason: .manualMatchingRequired,
        access: assignment.persistenceAccess, visit: &visit)
      return
    }

    attempt.matchedMovie = movie
    attempt.acceptedMovieReleaseDates = savedReleaseDates(assignment.releaseDates, movie: movie, candidate: candidate,
      saved: visit.processingCache.folders[candidate.name]) ?? []
    visit.activityLog?.movie = movie
    attempt.failedProcessingStage = .artwork
    visit.activityLog?.stage = .artwork
    let imageData: Data
    do {
      imageData = try await posterBytes(for: assignment.posterPath, visit: &visit)
    } catch {
      try visit.searchCorrection?.validate()
      throw error
    }

    guard try await validateSelectedCandidate(candidate, root: assignment.root, visit: &visit) else { return }

    attempt.failedProcessingStage = .assignPoster
    visit.activityLog?.stage = .assignPoster
    let result = try assign(imageData, to: candidate, in: assignment.root,
      localInformationReadResultSHA256: attempt.localInformationReadResultSHA256,
      searchCorrection: visit.searchCorrection)
    visit.activityLog?.append(result == .assigned ? .posterApplied : .preserved)

    if result == .existingIconPreserved, attempt.searchCorrection?.captured.correction != .none {
      try saveAssignedState(
        visit.processingCache, to: assignment.persistenceAccess, candidate: candidate, root: assignment.root,
        processingState: &visit.collectionProcessingRecord, activity: visit.activityLog)
      return
    }

    var completedRecord = FolderProcessingCacheRecord(
      fingerprint: candidate.fingerprint,
      status: .processed,
      retryDate: .none,
      matchedMovieID: movie.id,
      posterPath: assignment.posterPath,
      movieTitle: movie.title,
      movieYear: movie.releaseYear,
      movieIdentitySource: attempt.movieIdentitySource ?? .conservativeMatch
    )
    completedRecord.localInformationReadResultSHA256 = attempt.localInformationReadResultSHA256
    completedRecord.searchCorrectionSHA256 = visit.searchCorrection?.sha256
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
    releaseDates: [MovieReleaseDate] = [], identitySource: MovieIdentitySource? = .none,
    access: PersistenceAccess, visit: inout AutomaticProcessingPass
  ) throws {
    if let context = visit.localInformationContexts[candidate.name] { try context.validate() }
    let saved = visit.processingCache.folders[candidate.name]
    let protectsSavedIdentity = saved?.fingerprint == candidate.fingerprint && saved?.protectsMovieIdentity == true
    recordUnresolved(candidate, in: &visit.processingCache, reason: reason, movie: movie, releaseDates: releaseDates)
    visit.processingCache.folders[candidate.name]?.localInformationReadResultSHA256 =
      visit.localInformationReadResults[candidate.name]?.sha256
    visit.recordCorrectionEvidence(
      for: candidate.name, correction: visit.searchCorrection, protectsSavedIdentity: protectsSavedIdentity)
    if let identitySource, movie != .none,
      visit.processingCache.folders[candidate.name]?.movieIdentitySource != .explicitSelection {
      visit.processingCache.folders[candidate.name]?.movieIdentitySource = identitySource
    }
    var record = unresolvedFolderResult(candidate, reason: reason, movie: movie)
    if let retained = visit.processingCache.folders[candidate.name], retained.matchedMovieID != .none {
      record = cachedFolderResult(candidate, saved: retained)
    }
    record.movieIdentitySource = visit.processingCache.folders[candidate.name]?.movieIdentitySource
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
      usesStubTMDbResponses: usesStubTMDbResponses, pageLimit: searchPageLimit)
    if let cached = visit.processingCache.queries[queryKey],
      now().timeIntervalSince(cached.createdAt) < configuration.queryCacheLifetime {
      let search = cached.searchResult()
      visit.activityLog?.matchingDiagnostics = visit.activityLog?.matchingDiagnostics?.recording(
        query: .init(title: title, year: year, language: movieMatchingConfiguration.searchLanguage,
          pageLimit: searchPageLimit, origin: .cached),
        search: .init(candidateCount: search.movies.count, hasMorePages: search.hasMorePages),
        candidates: search.movies.prefix(5).map { .init(movie: $0, verdict: .notEvaluated) })

      return search
    } else {
      let context = try visit.localInformationContexts[candidate.name] ?? informationContext(candidate, root: root,
        sha256: visit.localInformationReadResults[candidate.name]?.sha256
          ?? readMovieInformation(candidate, root: root).sha256, searchCorrection: visit.searchCorrection)
      visit.activityLog?.matchingDiagnostics = visit.activityLog?.matchingDiagnostics?.recording(
        query: .init(title: title, year: year, language: movieMatchingConfiguration.searchLanguage,
          pageLimit: searchPageLimit, origin: .fresh))
      let search = try await informationProvider(context).searchMovies(title: title, year: year,
        language: movieMatchingConfiguration.searchLanguage, pageLimit: searchPageLimit)
      visit.activityLog?.matchingDiagnostics = visit.activityLog?.matchingDiagnostics?.recording(
        search: .init(candidateCount: search.movies.count, hasMorePages: search.hasMorePages),
        candidates: search.movies.prefix(5).map { .init(movie: $0, verdict: .notEvaluated) })
      try Task.checkCancellation()

      guard try await validateSelectedCandidate(candidate, root: root, visit: &visit) else { return .none }

      visit.processingCache.queries[queryKey] = CachedMovieSearch(result: search, createdAt: now())
      try saveState(visit.processingCache, to: access, activity: visit.activityLog)

      return search
    }
  }

  /// Rechecks selected admission and identity before an awaited response can persist decisions.
  func validateSelectedCandidate(
    _ candidate: MovieFolderCandidate, root: URL, visit: inout AutomaticProcessingPass
  ) async throws -> Bool {
    if let context = visit.localInformationContexts[candidate.name] { try context.validate() }

    guard visit.selectedRetryChildName != .none else { return true }

    try Task.checkCancellation()
    try recovery?.validateProcessingAllowed()
    for attempt in 0..<8 {
      do {
        let settingsAccess = try checkIconChange(.automaticPosterAssignment, to: candidate, in: root)
        withExtendedLifetime(settingsAccess) {}
        break
      } catch ConfigurationError.busy {
        guard attempt < 7 else { throw ConfigurationError.busy }
        try await Task.sleep(for: .milliseconds(20))
      }
    }
    let currentCandidate = try actionCandidate(root: root, child: candidate.name, expectedIdentity: candidate.identity)
    let currentFolderResult = try folderProcessingResult(
      currentCandidate, root: root, saved: visit.processingCache.folders[currentCandidate.name])

    guard !currentCandidate.hasCustomIcon, currentFolderResult.processingState != .suppressed,
      currentFolderResult.processingState != .preserved else {
      visit.activityLog?.append(currentFolderResult)
      try recordFolderProcessing(currentFolderResult, in: &visit.collectionProcessingRecord,
        activity: visit.activityLog)
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
  /// At most one candidate's bounded local contents, retained only during its current attempt.
  var localInformationReadResults: [String: MovieFolderInformationReadResult] = [:]
  /// Immutable input contracts used before unresolved decisions are persisted.
  var localInformationContexts: [String: MovieInformationReadContext] = [:]
  /// Configured collection used for correction lookups.
  var correctionCollectionID: UUID? = .none
  /// Captured correction for the current member.
  var searchCorrection: AutomaticSearchCorrection? = .none
  /// Counts reported to the caller independently of durable outcomes.
  var processingSummary = ProcessingSummary()
  /// Whether provider admission ended this traversal without a normal collection-wide completion.
  var providerAdmissionStoppedPass = false
  /// Limits each provider poster path to one download attempt during this traversal.
  var attemptedPosterImagePaths = Set<String>()
  /// Restricts result deferral and interruption to one member for an explicit retry.
  var selectedRetryChildName: String? = .none

  /// Stamps an inconclusive result without changing a previously confirmed identity's protection.
  mutating func recordCorrectionEvidence(
    for folder: String, correction: AutomaticSearchCorrection?, protectsSavedIdentity: Bool
  ) {
    guard let correction, !protectsSavedIdentity else { return }

    let digest = correction.sha256
    let hasMovie = processingCache.folders[folder]?.matchedMovieID != .none
    processingCache.folders[folder]?.searchCorrectionSHA256 = digest
    if digest != .none && hasMovie { processingCache.folders[folder]?.provisionalCorrectedMatch = true }
  }
}

/// Evidence retained as a fresh attempt advances across suspension points.
struct FolderPosterAssignmentAttemptResult {
  /// The stage used when reporting a failed operation.
  var failedProcessingStage: FolderProcessingStage = .parse
  /// Captured digest stamped on every outcome from this attempt.
  var localInformationReadResultSHA256: String? = .none
  /// Correction evidence retained only for fresh automatic matching attempts.
  var searchCorrection: AutomaticSearchCorrection? = .none
  /// Whether the attempt began with a saved identity that must remain protected.
  var protectsSavedIdentity = false
  /// Source that actually established this attempt's provider identity.
  var movieIdentitySource: MovieIdentitySource? = .none
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
