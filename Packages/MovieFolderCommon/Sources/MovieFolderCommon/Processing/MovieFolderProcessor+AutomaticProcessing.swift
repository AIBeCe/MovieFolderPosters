import FileSystem
import Foundation
import Network
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
    try Task.checkCancellation()
    try recovery?.validateProcessingAllowed()
    let coordinationLease = try acquireCoordinationLease(for: root)
    defer { withExtendedLifetime(coordinationLease) {} }
    guard let lease = try persistence.acquireLease(for: Self.rootLeaseKey(for: root)) else {
      throw PosterActionError.busy
    }
    defer { withExtendedLifetime(lease) {} }
    guard let snapshot = try processingStore?.read(rootID: processingContext.rootID),
      snapshot.context == processingContext,
      let record = snapshot.folders.first(where: { $0.name == child })
    else { throw CollectionProcessingError.configurationChanged }
    guard record.identity == expectedIdentity else { throw PosterActionError.changedIdentity }
    let candidate = try actionCandidate(root: root, child: child, expectedIdentity: expectedIdentity)
    guard !record.isVerifiedDone, record.state != .preserved, record.state != .suppressed,
      !candidate.hasCustomIcon,
      try !fileSystem.isPosterSuppressed(toChild: child, in: root) else { return .notEligible }
    switch record.reason {
    case .noSuitableMovie, .ambiguousMovie, .parsingProblem, .missingArtwork, .authentication:
      return .notEligible
    default: break
    }
    let cache = try loadState(from: lease)
    let prior = cache.folders[child]
    let sameFingerprint = prior?.fingerprint == candidate.fingerprint
    if sameFingerprint, prior?.blocksAutomaticRecovery == true { return .notEligible }
    let needsLegacyReassessment = sameFingerprint && prior?.needsLegacyReassessment == true
    if !needsLegacyReassessment, let deadline = cache.rootBackoffUntil, deadline > now() {
      return .waiting(until: deadline)
    }
    if !needsLegacyReassessment, prior?.processingReason != .interrupted, record.reason != .interrupted {
      let cacheDeadline = sameFingerprint ? prior?.retryDate : .none
      if let deadline = [cacheDeadline, record.retryAt].compactMap({ $0 }).max(), deadline > now() {
        return .waiting(until: deadline)
      }
    }
    do {
      let settingsLease = try mutationGuard?.movieFolderProcessorWillPerformManualMutation(self)
      withExtendedLifetime(settingsLease) {}
    }
    var visit = AutomaticProcessingVisit(
      cache: cache, recording: try recordProcessingStart(context: processingContext, action: .manual, child: child),
      selectedChild: child)
    defer { interruptUnfinishedProcessing(&visit.recording, child: child) }
    if try !shouldSkipCandidate(candidate, root: root, visit: &visit),
      try !reuseCachedDecision(candidate, root: root, lease: lease, visit: &visit) {
      visit.didStopEarly = try await processCandidate(candidate, root: root, lease: lease, visit: &visit)
    }
    try finishProcessingOperation(&visit.recording, state: visit.didStopEarly ? .partial : .completed)

    return .attempted(visit.summary, stopSelection: visit.didStopEarly)
  }

  /// Processes immediate child folders with bounded retries, cache reuse, and identity-checked icon writes.
  ///
  /// - Parameters:
  ///   - root: The authorized collection directory containing the immediate child.
  ///   - processingContext: Current settings and root generation; required when authoritative recording is configured.
  /// - Returns: Counts and retry evidence from this visit; contention is reported in the summary.
  /// - Throws: Cancellation, root-access, authorization, or persistence errors; recoverable folder failures are
  /// counted.
  public func process(
    root: URL, processingContext: CollectionProcessingContext? = .none
  ) async throws -> ProcessingSummary {
    try Task.checkCancellation()
    try recovery?.validateProcessingAllowed()
    let rootKey = Self.rootLeaseKey(for: root)
    let coordinationLease: PersistenceLease?
    do {
      coordinationLease = try acquireCoordinationLease(for: root)
    } catch PosterActionError.busy {
      return ProcessingSummary(rootLeaseUnavailable: true)
    }
    defer { withExtendedLifetime(coordinationLease) {} }
    guard let lease = try persistence.acquireLease(for: rootKey) else {
      return ProcessingSummary(rootLeaseUnavailable: true)
    }
    defer { withExtendedLifetime(lease) {} }

    do {
      let settingsLease = try mutationGuard?.movieFolderProcessor(self, willPerformAutomaticMutationIn: root)
      withExtendedLifetime(settingsLease) {}
    }
    var visit = AutomaticProcessingVisit(
      recording: try recordProcessingStart(context: processingContext, action: .automatic))
    defer { interruptUnfinishedProcessing(&visit.recording) }
    let candidates = try processingCandidates(in: root, recording: &visit.recording)
    visit.cache = try loadState(from: lease)
    let currentTime = now()
    var stateChanged = pruneCache(&visit.cache, candidates: candidates, currentTime: currentTime)
    try assessExistingIcons(candidates, root: root, visit: &visit)
    if recovery == nil, !hasLegacyReassessment(candidates, cache: visit.cache),
      let backoff = visit.cache.rootBackoffUntil, backoff > currentTime {
      if stateChanged { try saveState(visit.cache, to: lease) }
      visit.summary.rootBackoffUntil = backoff
      deferPendingFolderAssessments(&visit.recording, until: backoff)
      try finishProcessingOperation(&visit.recording, state: .partial)

      return visit.summary
    }
    if visit.cache.rootBackoffUntil != .none { stateChanged = true }
    visit.cache.rootBackoffUntil = .none
    if stateChanged { try saveState(visit.cache, to: lease) }
    for candidate in candidates {
      try Task.checkCancellation()
      try recovery?.validateProcessingAllowed()
      if try shouldSkipCandidate(candidate, root: root, visit: &visit) { continue }
      if try reuseCachedDecision(candidate, root: root, lease: lease, visit: &visit) { continue }
      if try await processCandidate(candidate, root: root, lease: lease, visit: &visit) {
        visit.didStopEarly = true
        break
      }
    }
    try finishProcessingOperation(&visit.recording, state: visit.didStopEarly ? .partial : .completed)

    return visit.summary
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
      if currentTime.timeIntervalSince(cached.createdAt) >= Self.queryCacheLifetime {
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
      try Task.checkCancellation()
      do {
        if try restyleOwnedPosterIfPossible(candidate, in: root, state: visit.cache) {
          visit.summary.restyled += 1
        } else {
          visit.summary.skippedExistingIcons += 1
        }
        try recordFolderProcessing(
          assessFolderProcessing(candidate, root: root, saved: visit.cache.folders[candidate.name]),
          in: &visit.recording)
      } catch let error as CollectionProcessingError {
        throw error
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as ProcessingRecoveryError {
        throw error
      } catch {
        if Task.isCancelled { throw CancellationError() }
        visit.summary.transientFailures += 1
        if visit.recording != .none {
          var record = (try? assessFolderProcessing(candidate, root: root, saved: visit.cache.folders[candidate.name]))
            ?? failedFolderAssessment(candidate, stage: .validateIdentity)
          record.lastFailure = FolderProcessingFailure(reason: .filesystem, stage: .assignPoster, occurredAt: now())
          if record.state != .done { record.reason = .filesystemFailure }
          try recordFolderProcessing(record, in: &visit.recording)
        }
      }
    }
  }

  /// Records suppression or inspection failures before considering a cached decision.
  private func shouldSkipCandidate(
    _ candidate: FolderCandidate, root: URL, visit: inout AutomaticProcessingVisit
  ) throws -> Bool {
    do {
      if try fileSystem.isPosterSuppressed(toChild: candidate.name, in: root) {
        if !candidate.hasCustomIcon {
          try recordFolderProcessing(FolderProcessingRecord(
            name: candidate.name, identity: candidate.identity, state: .suppressed,
            reason: .policySuppressed, ownership: .none, assessedAt: now(), fingerprint: candidate.fingerprint),
            in: &visit.recording)
        }
        return true
      }
    } catch let error as CollectionProcessingError {
      throw error
    } catch {
      visit.summary.transientFailures += 1
      try recordFolderProcessing(failedFolderAssessment(candidate, stage: .validateIdentity), in: &visit.recording)
      return true
    }
    if candidate.hasCustomIcon {
      return true
    }

    return false
  }

  /// Reuses unchanged decisions and reports whether this member is already handled.
  private func reuseCachedDecision(
    _ candidate: FolderCandidate, root: URL, lease: PersistenceLease, visit: inout AutomaticProcessingVisit
  ) throws -> Bool {
    let priorRecord = visit.cache.folders[candidate.name]
    let sameFingerprint = priorRecord?.fingerprint == candidate.fingerprint
    if sameFingerprint, let record = priorRecord {
      if record.blocksAutomaticRecovery || (record.processingReason == .authentication && recovery == nil) {
        visit.summary.unresolved += 1
        try recordFolderProcessing(cachedFolderAssessment(candidate, saved: record), in: &visit.recording)
        return true
      }
      if record.status == .processed,
        let movieID = record.matchedMovieID,
        let posterPath = record.posterPath,
        let cached = cachedPoster(for: posterPath) {
        try assignCachedPoster(
          CachedPosterAssignment(bytes: cached, movieID: movieID, posterPath: posterPath, record: record),
          candidate: candidate, root: root, lease: lease, visit: &visit)
        return true
      }
      if record.status != .processed, !record.needsLegacyReassessment,
        record.processingReason != .interrupted, let retryDate = record.retryDate, retryDate > now() {
        visit.summary.skippedRetryWindow += 1
        try recordFolderProcessing(cachedFolderAssessment(candidate, saved: record), in: &visit.recording)
        return true
      }
      if record.needsLegacyReassessment || record.processingReason == .incompleteSearch,
        case .parsed(let parsed) = parser.parse(candidate.name) {
        // A retry must not establish a new classification from the same inconclusive search.
        visit.cache.queries.removeValue(forKey: Self.queryKey(title: parsed.title, year: parsed.year))
        visit.cache.folders[candidate.name] = FolderRecord(
          fingerprint: candidate.fingerprint, status: .transientFailure, retryDate: .none,
          matchedMovieID: record.matchedMovieID, posterPath: record.posterPath, processingReason: .interrupted,
          movieTitle: record.movieTitle, movieYear: record.movieYear, movieIdentitySource: record.movieIdentitySource)
        try saveState(visit.cache, to: lease)
      }
    }

    return false
  }

  /// Assigns cached artwork while preserving failure and durable-record semantics.
  private func assignCachedPoster(
    _ assignment: CachedPosterAssignment, candidate: FolderCandidate, root: URL,
    lease: PersistenceLease, visit: inout AutomaticProcessingVisit
  ) throws {
    do {
      let result = try assign(assignment.bytes, to: candidate, in: root)
      visit.cache.folders[candidate.name] = FolderRecord(
        fingerprint: candidate.fingerprint,
        status: .processed,
        retryDate: .none,
        matchedMovieID: assignment.movieID,
        posterPath: assignment.posterPath,
        movieTitle: assignment.record.movieTitle,
        movieYear: assignment.record.movieYear,
        movieIdentitySource: assignment.record.movieIdentitySource ?? .savedDecision
      )
      try saveAssignedState(visit.cache, to: lease, candidate: candidate, root: root, processingState: &visit.recording)
      if case .assigned = result { visit.summary.assigned += 1 }
    } catch let error as CollectionProcessingError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as ProcessingRecoveryError {
      throw error
    } catch {
      if Task.isCancelled { throw CancellationError() }
      try validateSelectedCandidate(candidate, root: root, visit: visit)
      recordTransientFailure(candidate, in: &visit.cache)
      try saveState(visit.cache, to: lease)
      visit.summary.transientFailures += 1
      try recordFolderProcessing(failedFolderAssessment(candidate, stage: .assignPoster), in: &visit.recording)
    }
  }

  /// Runs one fresh attempt and reports whether provider backoff must end the visit.
  private func processCandidate(
    _ candidate: FolderCandidate, root: URL, lease: PersistenceLease, visit: inout AutomaticProcessingVisit
  ) async throws -> Bool {
    visit.summary.examined += 1
    var attempt = PosterAttempt()
    do {
      try await matchAndAssignPoster(candidate, root: root, lease: lease, visit: &visit, attempt: &attempt)
    } catch let error as CollectionProcessingError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as ProcessingRecoveryError {
      try validateSelectedCandidate(candidate, root: root, visit: visit)
      return try recordRecoveryAdmissionFailure(
        error, candidate: candidate, lease: lease, visit: &visit, attempt: attempt)
    } catch let error as TMDbError {
      try validateSelectedCandidate(candidate, root: root, visit: visit)
      return try recordProviderFailure(error, candidate: candidate, lease: lease, visit: &visit, attempt: attempt)
    } catch {
      if Task.isCancelled { throw CancellationError() }
      try validateSelectedCandidate(candidate, root: root, visit: visit)
      recordTransientFailure(candidate, in: &visit.cache, stage: attempt.stage, movie: attempt.movie)
      try saveState(visit.cache, to: lease)
      visit.summary.transientFailures += 1
      let record = failedFolderAssessment(candidate, stage: attempt.stage, movie: attempt.movie)
      try recordFolderProcessing(record, in: &visit.recording)
    }

    return false
  }

  /// Retains the explicit admission reason without converting paused work into an ordinary retry.
  private func recordRecoveryAdmissionFailure(
    _ error: ProcessingRecoveryError, candidate: FolderCandidate, lease: PersistenceLease,
    visit: inout AutomaticProcessingVisit, attempt: PosterAttempt
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
    visit.cache.folders[candidate.name]?.retryDate = retryAt
    try saveState(visit.cache, to: lease)
    var record = failedFolderAssessment(candidate, stage: attempt.stage, movie: attempt.movie,
      reason: reason, failureReason: failure)
    record.retryAt = retryAt
    try recordFolderProcessing(record, in: &visit.recording)
    visit.summary.rootBackoffUntil = retryAt
    if let retryAt { deferPendingFolderAssessments(&visit.recording, until: retryAt, child: visit.selectedChild) }

    return true
  }

  /// Saves typed provider evidence and any root-local delay before ending the current attempt.
  private func recordProviderFailure(
    _ error: TMDbError, candidate: FolderCandidate, lease: PersistenceLease,
    visit: inout AutomaticProcessingVisit, attempt: PosterAttempt
  ) throws -> Bool {
    if Task.isCancelled { throw CancellationError() }
    let evidence = providerFailureEvidence(error, stage: attempt.stage)
    recordTransientFailure(
      candidate, in: &visit.cache, stage: attempt.stage, movie: attempt.movie,
      reason: evidence.reason, failureReason: evidence.failureReason)
    if let retryDate = try effectiveRootBackoff(for: error) {
      visit.cache.rootBackoffUntil = retryDate
      visit.cache.folders[candidate.name]?.retryDate = retryDate
      try saveState(visit.cache, to: lease)
      visit.summary.rootBackoffUntil = retryDate
      var record = failedFolderAssessment(
        candidate, stage: attempt.stage, movie: attempt.movie,
        reason: evidence.reason, failureReason: evidence.failureReason)
      record.retryAt = retryDate
      try recordFolderProcessing(record, in: &visit.recording)
      deferPendingFolderAssessments(&visit.recording, until: retryDate, child: visit.selectedChild)
      return true
    }
    try saveState(visit.cache, to: lease)
    visit.summary.transientFailures += 1
    let record = failedFolderAssessment(
      candidate, stage: attempt.stage, movie: attempt.movie,
      reason: evidence.reason, failureReason: evidence.failureReason)
    try recordFolderProcessing(record, in: &visit.recording)
    if evidence.reason == .authentication { return true }

    return false
  }

  /// Matches a member and assigns validated artwork in the original safety order.
  private func matchAndAssignPoster(
    _ candidate: FolderCandidate, root: URL, lease: PersistenceLease,
    visit: inout AutomaticProcessingVisit, attempt: inout PosterAttempt
  ) async throws {
    guard case .parsed(let parsed) = parser.parse(candidate.name) else {
      recordUnresolved(candidate, in: &visit.cache)
      try saveState(visit.cache, to: lease)
      visit.summary.unresolved += 1
      let record = unresolvedFolderAssessment(candidate, reason: .parsingProblem)
      try recordFolderProcessing(record, in: &visit.recording)
      return
    }

    attempt.stage = .search
    let search = try await searchMovies(
      title: parsed.title, year: parsed.year, candidate: candidate, root: root, lease: lease, visit: &visit)

    let identityResult = matcher.identify(title: parsed.title, year: parsed.year, search: search)
    guard case .matched(let movie) = identityResult, let posterPath = movie.posterPath,
      !posterPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      let (reason, identifiedMovie) = unresolvedIdentity(identityResult)
      recordUnresolved(candidate, in: &visit.cache, reason: reason, movie: identifiedMovie)
      try saveState(visit.cache, to: lease)
      visit.summary.unresolved += 1
      let record = unresolvedFolderAssessment(candidate, reason: reason, movie: identifiedMovie)
      try recordFolderProcessing(record, in: &visit.recording)
      return
    }

    attempt.movie = movie
    attempt.stage = .artwork
    let imageData = try await posterBytes(for: posterPath)

    attempt.stage = .assignPoster
    let result = try assign(imageData, to: candidate, in: root)
    visit.cache.folders[candidate.name] = FolderRecord(
      fingerprint: candidate.fingerprint,
      status: .processed,
      retryDate: .none,
      matchedMovieID: movie.id,
      posterPath: posterPath,
      movieTitle: movie.title,
      movieYear: movie.releaseYear,
      movieIdentitySource: .conservativeMatch
    )
    try saveAssignedState(visit.cache, to: lease, candidate: candidate, root: root, processingState: &visit.recording)
    if case .assigned = result { visit.summary.assigned += 1 }
  }

  /// Retains the conservative unresolved reason and any identified movie.
  private func unresolvedIdentity(_ identityResult: MovieMatchResult) -> (FolderProcessingReason, MovieMetadata?) {
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
    title: String, year: Int?, candidate: FolderCandidate, root: URL,
    lease: PersistenceLease, visit: inout AutomaticProcessingVisit
  ) async throws -> MovieSearchResult {
    let queryKey = Self.queryKey(title: title, year: year)
    if let cached = visit.cache.queries[queryKey],
      now().timeIntervalSince(cached.createdAt) < Self.queryCacheLifetime {
      return cached.searchResult()
    } else {
      let search = try await provider.searchMovies(title: title, year: year)
      try Task.checkCancellation()
      try validateSelectedCandidate(candidate, root: root, visit: visit)
      visit.cache.queries[queryKey] = CachedSearch(result: search, createdAt: now())
      try saveState(visit.cache, to: lease)

      return search
    }
  }

  /// Rechecks selected admission and identity before an awaited response can persist decisions.
  private func validateSelectedCandidate(
    _ candidate: FolderCandidate, root: URL, visit: AutomaticProcessingVisit
  ) throws {
    guard visit.selectedChild != .none else { return }
    try Task.checkCancellation()
    try recovery?.validateProcessingAllowed()
    let settingsLease = try mutationGuard?.movieFolderProcessorWillPerformManualMutation(self)
    defer { withExtendedLifetime(settingsLease) {} }
    _ = try actionCandidate(root: root, child: candidate.name, expectedIdentity: candidate.identity)
  }

  /// Reuses validated artwork or downloads, validates, and best-effort caches it.
  private func posterBytes(for posterPath: String) async throws -> Data {
    if let cached = cachedPoster(for: posterPath) {
      return cached
    } else {
      let imageData = try await provider.downloadPoster(path: posterPath)
      try Task.checkCancellation()
      guard Self.isValidPoster(imageData) else { throw ProcessingFailure.invalidPoster }
      try? fileSystem.writeData(
        imageData, named: Self.posterCacheName(posterPath),
        in: cacheDirectory)

      return imageData
    }
  }
}

/// Mutable values owned by one automatic traversal, never shared between actor calls.
private struct AutomaticProcessingVisit {
  /// Operational decisions and query cache, loaded after inventory completes.
  var cache = ProcessingState()
  /// Authoritative result document checkpointed throughout the visit.
  var recording: CollectionProcessingState?
  /// Counts reported to the caller independently of durable outcomes.
  var summary = ProcessingSummary()
  /// Whether provider admission ended this traversal without a normal collection-wide completion.
  var didStopEarly = false
  /// Restricts result deferral and interruption to one member for an explicit retry.
  var selectedChild: String? = .none
}

/// Evidence retained as a fresh attempt advances across suspension points.
private struct PosterAttempt {
  /// The stage used when reporting a failed operation.
  var stage: FolderProcessingStage = .parse
  /// The established movie identity, if matching succeeded.
  var movie: MovieMetadata?
}

/// Cached decision and artwork reused without repeating a metadata request.
private struct CachedPosterAssignment {
  /// Validated cached source artwork.
  let bytes: Data
  /// Saved provider identity.
  let movieID: Int
  /// Saved provider-relative artwork path.
  let posterPath: String
  /// Saved title and identity provenance.
  let record: FolderRecord
}
