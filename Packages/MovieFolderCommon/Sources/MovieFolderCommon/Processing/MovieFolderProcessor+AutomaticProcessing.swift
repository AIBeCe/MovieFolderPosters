import FileSystem
import Foundation
import MovieFolderParsing
import Network
import Persistence

extension MovieFolderProcessor {
  /// Processes immediate child folders with bounded retries, cache reuse, and identity-checked icon writes.
  ///
  /// - Parameters:
  ///   - root: The authorized collection directory containing the immediate child.
  ///   - processingContext: Current settings and root generation; required when authoritative recording is configured.
  ///   - activityLogContext: Fresh trusted collection capture for this visit; omitted values use composition context.
  /// - Returns: Counts and retry evidence from this visit; contention is reported in the summary.
  /// - Throws: Cancellation, root-access, authorization, or persistence errors; recoverable folder failures are
  /// counted.
  public func process(
    root: URL, processingContext: CollectionProcessingContext? = .none,
    activityLogContext: MovieFolderActivityLogContext? = .none
  ) async throws -> ProcessingSummary {
    let activity = ProcessorActivityLog(
      context: activityLogContext ?? self.activityLogContext, action: .automaticProcessing)
    do {
      let result = try await performProcess(
        root: root, processingContext: processingContext, activity: activity)
      await flushActivityLog(activity)

      return result
    } catch {
      recordActivityFailure(error, in: activity)
      await flushActivityLog(activity)
      throw error
    }
  }

  /// Executes the operation while retaining its existing processing access and safety fences.
  private func performProcess(
    root: URL, processingContext: CollectionProcessingContext? = .none, activity: ProcessorActivityLog
  ) async throws -> ProcessingSummary {
    try Task.checkCancellation()
    try recovery?.validateProcessingAllowed()
    guard !processingConfiguration.isPaused else { throw CollectionProcessingError.configurationChanged }
    let rootKey = Self.processingStateKey(for: root)
    let coordinationAccess: PersistenceAccess?
    do {
      coordinationAccess = try acquireCoordinationAccess(for: root)
    } catch PosterActionError.busy {
      return ProcessingSummary(rootAccessUnavailable: true)
    }
    defer { withExtendedLifetime(coordinationAccess) {} }

    guard let access = try persistence.acquireAccess(for: rootKey) else {
      return ProcessingSummary(rootAccessUnavailable: true)
    }

    defer { withExtendedLifetime(access) {} }

    do {
      let settingsAccess = try processingVerifier?.checkAutomaticProcessing(in: root)
      withExtendedLifetime(settingsAccess) {}
    }

    if let processingContext, let previous = try? processingStore?.read(rootID: processingContext.rootID) {
      activity.priorAssessments = previous.folders.reduce(into: [:]) { $0[$1.name] = $1 }
    }

    var visit = AutomaticProcessingVisit(
      recording: try recordProcessingStart(context: processingContext, action: .automatic), activity: activity)
    defer { interruptUnfinishedProcessing(&visit.recording) }
    let inventory = try processingCandidates(in: root, recording: &visit.recording)
    let candidates = inventory.filter { !processingConfiguration.excludesFolder(identity: $0.identity) }
    visit.summary.excluded = inventory.count - candidates.count
    for candidate in inventory where processingConfiguration.excludesFolder(identity: candidate.identity) {
      let record = FolderProcessingRecord(
        name: candidate.name, identity: candidate.identity, state: .excluded, reason: .explicitExclusion,
        assessedAt: now(), fingerprint: candidate.fingerprint)
      visit.activity?.append(record, onlyWhenChanged: true)
      try recordFolderProcessing(record, in: &visit.recording, activity: visit.activity)
    }
    visit.cache = try loadState(from: access)

    let currentTime = now()
    var stateChanged = pruneCache(&visit.cache, candidates: inventory, currentTime: currentTime)
    try assessExistingIcons(candidates, root: root, visit: &visit)

    if try deferForProviderBackoff(
      candidates, currentTime: currentTime, stateChanged: stateChanged, access: access, visit: &visit
    ) { return visit.summary }

    if visit.cache.providerRetryAt != .none { stateChanged = true }
    visit.cache.providerRetryAt = .none
    if stateChanged { try saveState(visit.cache, to: access, activity: visit.activity) }

    try await repairExistingIconArtwork(candidates, root: root, access: access, visit: &visit)

    for candidate in candidates {
      if visit.didStopEarly { break }
      visit.activity?.begin(candidate.name,
        movie: savedActivityMovie(visit.cache.folders[candidate.name], candidate: candidate))
      try Task.checkCancellation()
      try recovery?.validateProcessingAllowed()
      if try shouldSkipCandidate(candidate, root: root, visit: &visit) { continue }
      if try await reuseCachedDecision(candidate, root: root, access: access, visit: &visit) { continue }
      if try await processCandidate(candidate, root: root, access: access, visit: &visit) {
        visit.didStopEarly = true
        break
      }
    }

    try finishProcessingRun(
      &visit.recording, state: visit.didStopEarly ? .partial : .completed, activity: visit.activity)
    visit.summary.nextAutomaticRetryAt = visit.recording?.folders.compactMap(\.automaticRetryAt).min()

    return visit.summary
  }

  /// Applies a persisted provider delay before any source artwork repair or fresh processing.
  /// - Parameters:
  ///   - candidates: Immediate child folders in this visit.
  ///   - currentTime: Instant used for retry eligibility.
  ///   - stateChanged: Whether cache pruning needs to be saved before deferral.
  ///   - access: Held persistence access for this root.
  ///   - visit: Traversal and authoritative recording state.
  /// - Returns: Whether the visit was deferred.
  /// - Throws: Persistence or recording errors.
  private func deferForProviderBackoff(
    _ candidates: [FolderCandidate], currentTime: Date, stateChanged: Bool,
    access: PersistenceAccess, visit: inout AutomaticProcessingVisit
  ) throws -> Bool {
    guard recovery == nil, !hasLegacyReassessment(candidates, cache: visit.cache),
      let backoff = visit.cache.providerRetryAt, backoff > currentTime
    else { return false }

    if stateChanged { try saveState(visit.cache, to: access, activity: visit.activity) }

    visit.summary.providerRetryAt = backoff
    for candidate in candidates where !candidate.hasCustomIcon {
      visit.activity?.begin(candidate.name,
        movie: savedActivityMovie(visit.cache.folders[candidate.name], candidate: candidate))
      visit.activity?.append(.deferred, reason: .retryDeferred, retryAt: backoff)
    }
    deferPendingFolderAssessments(&visit.recording, until: backoff)
    try finishProcessingRun(&visit.recording, state: .partial, activity: visit.activity)

    return true
  }

  /// Detects unchanged reasonless decisions whose obsolete root delay cannot block their fresh classification.
  private func hasLegacyReassessment(_ candidates: [FolderCandidate], cache: ProcessingState) -> Bool {
    candidates.contains {
      let saved = cache.folders[$0.name]

      return saved?.fingerprint == $0.fingerprint && saved?.needsLegacyReassessment == true
    }
  }

  /// Inventories and checkpoints all immediate members before authorizing writes.
  private func processingCandidates(
    in root: URL, recording: inout CollectionProcessingState?
  ) throws -> [FolderCandidate] {
    do {
      if recording != .none {
        let inventory = try fileSystem.inventory(in: root)

        guard inventory.members.count <= 10_000 else {
          recording?.inventoryIssue = .capacityExceeded
          throw CollectionProcessingError.capacityExceeded
        }

        recording?.folders = inventory.members.map {
          FolderProcessingRecord(
            name: $0.name, identity: $0.identity,
            state: $0.candidate == .none ? .failed : .pending,
            reason: $0.candidate == .none ? .inspectionFailure : .inventoryPending,
            assessedAt: $0.candidate == .none ? now() : .none,
            fingerprint: $0.candidate?.fingerprint)
        }
        recording?.isInventoryComplete = inventory.isComplete
        recording?.inspectedAt = now()
        recording?.inventoryIssue = inventory.isComplete ? .none : .inspectionFailure
        try commitProcessingState(&recording)
        // An incomplete type inventory cannot authorize a fabricated population or new writes.

        guard inventory.isComplete else { throw ProcessingError.unavailableRoot }

        return inventory.members.compactMap(\.candidate)
      } else {
        return try fileSystem.candidates(in: root)
      }
    } catch let error as CollectionProcessingError {
      throw error
    } catch {
      throw ProcessingError.unavailableRoot
    }
  }

  /// Prunes disappeared folder decisions and expired query responses.
  private func pruneCache(_ state: inout ProcessingState, candidates: [FolderCandidate], currentTime: Date) -> Bool {
    var stateChanged = false
    let currentNames = Set(candidates.map(\.name))
    for name in Array(state.folders.keys) where !currentNames.contains(name) {
      state.folders.removeValue(forKey: name)
      stateChanged = true
    }

    for key in Array(state.queries.keys) {
      guard let cached = state.queries[key] else { continue }

      if currentTime.timeIntervalSince(cached.createdAt) >= configuration.queryCacheLifetime {
        state.queries.removeValue(forKey: key)
        stateChanged = true
      }
    }

    return stateChanged
  }

  /// Assesses and optionally restyles existing icons before provider backoff.
  private func assessExistingIcons(
    _ candidates: [FolderCandidate], root: URL, visit: inout AutomaticProcessingVisit
  ) throws {
    for candidate in candidates where candidate.hasCustomIcon {
      visit.activity?.begin(candidate.name,
        movie: savedActivityMovie(visit.cache.folders[candidate.name], candidate: candidate), stage: .assignPoster)
      try Task.checkCancellation()
      do {
        if try restyleOwnedPosterIfPossible(candidate, in: root, state: visit.cache) {
          visit.summary.restyled += 1
          visit.activity?.movie = savedActivityMovie(visit.cache.folders[candidate.name], candidate: candidate)
          visit.activity?.append(.posterRestyled)
        } else {
          visit.summary.skippedExistingIcons += 1
        }
        let assessment = try assessFolderProcessing(candidate, root: root, saved: visit.cache.folders[candidate.name])
        visit.activity?.append(assessment, onlyWhenChanged: true)
        try recordFolderProcessing(assessment, in: &visit.recording, activity: visit.activity)
      } catch let error as CollectionProcessingError {
        throw error
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as ProcessingRecoveryError {
        throw error
      } catch {
        if Task.isCancelled { throw CancellationError() }
        visit.summary.transientFailures += 1
        visit.activity?.append(.failed, reason: .filesystemFailure,
          failure: MovieFolderActivityLogEvent.failureEvidence(for: error, stage: .assignPoster, occurredAt: now()))
        if visit.recording != .none {
          var record = (try? assessFolderProcessing(candidate, root: root, saved: visit.cache.folders[candidate.name]))
            ?? failedFolderAssessment(candidate, stage: .validateIdentity)
          record.lastFailure = FolderProcessingFailure(reason: .filesystem, stage: .assignPoster, occurredAt: now())
          if record.state != .done { record.reason = .filesystemFailure }
          try recordFolderProcessing(record, in: &visit.recording, activity: visit.activity)
        }
      }
    }
  }

  /// Records suppression or inspection failures before considering a cached decision.
  func shouldSkipCandidate(
    _ candidate: FolderCandidate, root: URL, visit: inout AutomaticProcessingVisit
  ) throws -> Bool {
    visit.activity?.begin(candidate.name,
      movie: savedActivityMovie(visit.cache.folders[candidate.name], candidate: candidate))
    do {
      if try fileSystem.isPosterSuppressed(toChild: candidate.name, in: root) {
        if !candidate.hasCustomIcon {
          let record = FolderProcessingRecord(
            name: candidate.name, identity: candidate.identity, state: .suppressed,
            reason: .policySuppressed, ownership: .none, assessedAt: now(), fingerprint: candidate.fingerprint)
          visit.activity?.append(record, onlyWhenChanged: true)
          try recordFolderProcessing(record, in: &visit.recording, activity: visit.activity)
        }
        return true
      }
    } catch let error as CollectionProcessingError {
      throw error
    } catch {
      visit.summary.transientFailures += 1
      let record = failedFolderAssessment(candidate, stage: .validateIdentity)
      visit.activity?.append(record)
      try recordFolderProcessing(record, in: &visit.recording, activity: visit.activity)
      return true
    }
    if candidate.hasCustomIcon {
      return true
    }

    return false
  }

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
        visit.cache.queries.removeValue(forKey: Self.queryKey(title: parsed.title, year: parsed.year))
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
      let record = failedFolderAssessment(candidate, stage: attempt.stage, movie: attempt.movie)
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
    if let identitySource { record.movieIdentitySource = identitySource }
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
      if let identitySource { record.movieIdentitySource = identitySource }
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
    if let identitySource { record.movieIdentitySource = identitySource }
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

    let identityResult = matcher.matchMovie(title: parsed.title, year: parsed.year, search: search,
      configuration: movieMatchingConfiguration)

    guard case .matched(let movie) = identityResult, let posterPath = movie.posterPath,
      !posterPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      let (reason, identifiedMovie) = unresolvedIdentity(identityResult)
      try recordUnresolvedAttempt(candidate, reason: reason, movie: identifiedMovie, access: access, visit: &visit)
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
    let queryKey = Self.queryKey(title: title, year: year)
    if let cached = visit.cache.queries[queryKey],
      now().timeIntervalSince(cached.createdAt) < configuration.queryCacheLifetime {
      return cached.searchResult()
    } else {
      let search = try await provider.searchMovies(title: title, year: year)
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
