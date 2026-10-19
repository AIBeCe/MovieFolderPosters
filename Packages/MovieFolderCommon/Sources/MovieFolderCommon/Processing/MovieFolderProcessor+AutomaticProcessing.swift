import FileSystem
import Foundation
import Network
import Persistence

extension MovieFolderProcessor {
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
    if let backoff = visit.cache.rootBackoffUntil, backoff > currentTime {
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
      if try shouldSkipCandidate(candidate, root: root, visit: &visit) { continue }
      if try reuseCachedDecision(candidate, root: root, lease: lease, visit: &visit) { continue }
      if try await processCandidate(candidate, root: root, lease: lease, visit: &visit) { break }
    }
    try finishProcessingOperation(
      &visit.recording, state: visit.summary.rootBackoffUntil == .none ? .completed : .partial)

    return visit.summary
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
      if record.requiresManualResolution {
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
      if record.status != .processed, let retryDate = record.retryDate, retryDate > now() {
        visit.summary.skippedRetryWindow += 1
        try recordFolderProcessing(cachedFolderAssessment(candidate, saved: record), in: &visit.recording)
        return true
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
    } catch {
      if Task.isCancelled { throw CancellationError() }
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
    } catch let error as TMDbError {
      if Task.isCancelled { throw CancellationError() }
      if let retryDate = rootBackoff(for: error) {
        visit.cache.rootBackoffUntil = retryDate
        try saveState(visit.cache, to: lease)
        visit.summary.rootBackoffUntil = retryDate
        var record = failedFolderAssessment(candidate, stage: attempt.stage, movie: attempt.movie)
        record.reason = error == .authentication ? .authentication : .rateLimited
        record.retryAt = retryDate
        try recordFolderProcessing(record, in: &visit.recording)
        deferPendingFolderAssessments(&visit.recording, until: retryDate)
        return true
      }
      recordTransientFailure(candidate, in: &visit.cache, stage: attempt.stage, movie: attempt.movie)
      try saveState(visit.cache, to: lease)
      visit.summary.transientFailures += 1
      let record = failedFolderAssessment(candidate, stage: attempt.stage, movie: attempt.movie)
      try recordFolderProcessing(record, in: &visit.recording)
    } catch {
      if Task.isCancelled { throw CancellationError() }
      recordTransientFailure(candidate, in: &visit.cache, stage: attempt.stage, movie: attempt.movie)
      try saveState(visit.cache, to: lease)
      visit.summary.transientFailures += 1
      let record = failedFolderAssessment(candidate, stage: attempt.stage, movie: attempt.movie)
      try recordFolderProcessing(record, in: &visit.recording)
    }

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
    let search = try await searchMovies(title: parsed.title, year: parsed.year, lease: lease, visit: &visit)

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
    title: String, year: Int?, lease: PersistenceLease, visit: inout AutomaticProcessingVisit
  ) async throws -> MovieSearchResult {
    let queryKey = Self.queryKey(title: title, year: year)
    if let cached = visit.cache.queries[queryKey],
      now().timeIntervalSince(cached.createdAt) < Self.queryCacheLifetime {
      return cached.searchResult()
    } else {
      let search = try await provider.searchMovies(title: title, year: year)
      try Task.checkCancellation()
      visit.cache.queries[queryKey] = CachedSearch(result: search, createdAt: now())
      try saveState(visit.cache, to: lease)

      return search
    }
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
