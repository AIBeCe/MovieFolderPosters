import FileSystem
import Foundation
import Network
import Persistence

extension MovieFolderProcessor {
  /// Assigns cached artwork while preserving failure and durable-record semantics.
  /// - Parameters:
  ///   - assignment: Validated image bytes and saved movie decision.
  ///   - candidate: Folder whose icon may be assigned after identity validation.
  ///   - root: Authorized collection directory.
  ///   - lease: Held persistence lease for the root.
  ///   - visit: Traversal state receiving the resulting outcome.
  /// - Throws: Cancellation, authorization, or persistence errors.
  func assignCachedPoster(
    _ assignment: CachedPosterAssignment, candidate: FolderCandidate, root: URL,
    lease: PersistenceLease, visit: inout AutomaticProcessingVisit
  ) throws {
    do {
      let result = try assign(assignment.bytes, to: candidate, in: root)

      var cachedRecord = FolderRecord(
        fingerprint: candidate.fingerprint,
        status: .processed,
        retryDate: .none,
        matchedMovieID: assignment.movieID,
        posterPath: assignment.posterPath,
        movieTitle: assignment.record.movieTitle,
        movieYear: assignment.record.movieYear,
        movieIdentitySource: assignment.record.movieIdentitySource ?? .savedDecision
      )
      cachedRecord.nameParserRevision = assignment.record.nameParserRevision
      visit.cache.folders[candidate.name] = cachedRecord

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

      guard try validateSelectedCandidate(candidate, root: root, visit: &visit) else { return }

      let movie = MovieMetadata(
        id: assignment.movieID, title: assignment.record.movieTitle ?? "",
        originalTitle: assignment.record.movieTitle ?? "", releaseYear: assignment.record.movieYear,
        posterPath: assignment.posterPath)

      recordTransientFailure(candidate, in: &visit.cache, stage: .assignPoster, movie: movie)
      visit.cache.folders[candidate.name]?.movieIdentitySource = assignment.record.movieIdentitySource
      try saveState(visit.cache, to: lease)

      visit.summary.transientFailures += 1
      var failureRecord = failedFolderAssessment(candidate, stage: .assignPoster, movie: movie)
      failureRecord.movieIdentitySource = assignment.record.movieIdentitySource
      try recordFolderProcessing(failureRecord, in: &visit.recording)
    }
  }

  /// Repairs missing or invalid source artwork once while retaining the saved movie decision on failure.
  /// - Parameters:
  ///   - decision: Previously confirmed movie and provider artwork path.
  ///   - context: Folder identity, root, and persistence authority for this attempt.
  ///   - visit: Current traversal state and bounded download history.
  /// - Returns: Whether the saved decision handled this folder.
  /// - Throws: Cancellation, authorization, or persistence errors that stop processing.
  func repairCachedPoster(
    _ decision: SavedPosterDecision, context: ArtworkRepairContext, visit: inout AutomaticProcessingVisit
  ) async throws -> Bool {
    do {
      let bytes = try await posterBytes(for: decision.posterPath, visit: &visit)
      try assignCachedPoster(
        CachedPosterAssignment(
          bytes: bytes, movieID: decision.movieID, posterPath: decision.posterPath, record: decision.record),
        candidate: context.candidate, root: context.root, lease: context.lease, visit: &visit)
    } catch {
      visit.didStopEarly = try recordArtworkRepairFailure(
        error, decision: decision, context: context, visit: &visit)
      return true
    }

    return true
  }

  /// Stores a recoverable repair failure without discarding the confirmed provider movie.
  /// - Parameters:
  ///   - error: Failed download, validation, admission, or cache write.
  ///   - decision: Saved movie identity and its provenance.
  ///   - context: Folder and root authority for the failed attempt.
  ///   - visit: Traversal state receiving failure evidence.
  /// - Returns: Whether provider admission stops the current visit.
  /// - Throws: Cancellation, authorization, or persistence errors.
  private func recordArtworkRepairFailure(
    _ error: any Error, decision: SavedPosterDecision, context: ArtworkRepairContext,
    visit: inout AutomaticProcessingVisit
  ) throws -> Bool {
    if Task.isCancelled { throw CancellationError() }

    guard try validateSelectedCandidate(context.candidate, root: context.root, visit: &visit) else { return true }

    if let error = error as? CollectionProcessingError { throw error }
    if error is CancellationError { throw CancellationError() }
    if let error = error as? ProcessingRecoveryError {
      return try recordRecoveryAdmissionFailure(
        error, candidate: context.candidate, lease: context.lease, visit: &visit,
        attempt: PosterAttempt(stage: .artwork, movie: decision.movie),
        identitySource: decision.record.movieIdentitySource)
    }
    if let error = error as? TMDbError {
      return try recordProviderFailure(
        error, candidate: context.candidate, lease: context.lease, visit: &visit,
        attempt: PosterAttempt(stage: .artwork, movie: decision.movie),
        identitySource: decision.record.movieIdentitySource)
    }

    let evidence: (reason: FolderProcessingReason, failureReason: FolderProcessingFailureReason) =
      if case ProcessingFailure.invalidPoster = error {
        (.invalidResponse, .invalidResponse)
      } else if case ProcessingFailure.cacheWriteFailed = error {
        (.posterFailure, .storage)
      } else {
        (.posterFailure, .unavailable)
      }

    recordTransientFailure(
      context.candidate, in: &visit.cache, stage: .artwork, movie: decision.movie,
      reason: evidence.reason, failureReason: evidence.failureReason)
    if let identitySource = decision.record.movieIdentitySource {
      visit.cache.folders[context.candidate.name]?.movieIdentitySource = identitySource
    }
    try saveState(visit.cache, to: context.lease)

    visit.summary.transientFailures += 1
    var failureRecord = failedFolderAssessment(
      context.candidate, stage: .artwork, movie: decision.movie,
      reason: evidence.reason, failureReason: evidence.failureReason)
    failureRecord.movieIdentitySource = decision.record.movieIdentitySource
    try recordFolderProcessing(failureRecord, in: &visit.recording)

    return false
  }

  /// Repairs source artwork for verified existing icons without rewriting those folder icons.
  /// - Parameters:
  ///   - candidates: Immediate children from the authorized root inventory.
  ///   - root: Authorized collection directory.
  ///   - lease: Held persistence lease for the root.
  ///   - visit: Traversal state and per-path attempt bound.
  /// - Throws: Cancellation, filesystem, authorization, or persistence errors.
  func repairExistingIconArtwork(
    _ candidates: [FolderCandidate], root: URL, lease: PersistenceLease,
    visit: inout AutomaticProcessingVisit
  ) async throws {
    for candidate in candidates where candidate.hasCustomIcon {
      guard let record = visit.cache.folders[candidate.name], record.fingerprint == candidate.fingerprint,
        let movieID = record.matchedMovieID, let posterPath = record.posterPath
      else { continue }

      let retryIsDue = record.retryDate.map { $0 <= now() } ?? true

      guard record.status == .processed ||
        (record.status == .transientFailure && retryIsDue &&
          (record.lastFailure?.stage == .artwork ||
            (record.matchedMovieID != .none && record.posterPath != .none && record.lastFailure == .none
              && record.processingReason == .none))),
        !(record.processingReason == .authentication && recovery == nil)
      else { continue }

      guard try !fileSystem.isPosterSuppressed(toChild: candidate.name, in: root),
        try fileSystem.hasAssignedPoster(
          toChild: candidate.name, in: root, expectedIdentity: candidate.identity)
      else { continue }

      switch cachedPoster(for: posterPath) {
      case .valid: continue
      case .missing, .invalid: break
      }

      let decision = SavedPosterDecision(movieID: movieID, posterPath: posterPath, record: record)
      let context = ArtworkRepairContext(candidate: candidate, root: root, lease: lease)

      do {
        let bytes = try await downloadAndCachePoster(
          for: posterPath, visit: &visit, requireCacheWrite: true)

        guard case .valid(let cachedBytes) = cachedPoster(for: posterPath), cachedBytes == bytes else {
          throw ProcessingFailure.cacheWriteFailed
        }
      } catch {
        if try recordArtworkRepairFailure(
          error, decision: decision, context: context, visit: &visit) {
          visit.didStopEarly = true
          return
        }

        continue
      }

      var repairedRecord = FolderRecord(
        fingerprint: candidate.fingerprint, status: .processed, retryDate: .none,
        matchedMovieID: movieID, posterPath: posterPath, movieTitle: record.movieTitle,
        movieYear: record.movieYear, movieIdentitySource: record.movieIdentitySource ?? .savedDecision)
      repairedRecord.nameParserRevision = record.nameParserRevision
      repairedRecord.lastFailure = .none
      visit.cache.folders[candidate.name] = repairedRecord

      try saveAssignedState(
        visit.cache, to: lease, candidate: candidate, root: root, processingState: &visit.recording)
    }
  }

  /// Reuses validated artwork or downloads, validates, and best-effort caches it.
  /// - Parameters:
  ///   - posterPath: Provider-relative artwork path.
  ///   - visit: Traversal state recording attempted paths.
  /// - Returns: Complete image bytes suitable for icon assignment.
  /// - Throws: Provider, cancellation, or image validation errors.
  func posterBytes(
    for posterPath: String, visit: inout AutomaticProcessingVisit
  ) async throws -> Data {
    switch cachedPoster(for: posterPath) {
    case .valid(let cached): return cached
    case .missing, .invalid: return try await downloadAndCachePoster(for: posterPath, visit: &visit)
    }
  }

  /// Downloads a complete source image and caches it without assigning a folder icon.
  /// - Parameters:
  ///   - posterPath: Provider-relative artwork path.
  ///   - visit: Traversal state enforcing one download attempt per path.
  ///   - requireCacheWrite: Whether persistence is required before considering repair successful.
  /// - Returns: Validated image bytes.
  /// - Throws: Provider, cancellation, image validation, or required cache write errors.
  private func downloadAndCachePoster(
    for posterPath: String, visit: inout AutomaticProcessingVisit, requireCacheWrite: Bool = false
  ) async throws -> Data {
    guard visit.attemptedPosterPaths.insert(posterPath).inserted else {
      if case .valid(let cached) = cachedPoster(for: posterPath) { return cached }
      throw ProcessingFailure.invalidPoster
    }

    let imageData = try await provider.downloadPoster(path: posterPath)
    try Task.checkCancellation()

    guard Self.isValidPoster(imageData) else { throw ProcessingFailure.invalidPoster }

    if requireCacheWrite {
      try fileSystem.writeData(imageData, named: Self.posterCacheName(posterPath), in: cacheDirectory)
    } else {
      try? fileSystem.writeData(imageData, named: Self.posterCacheName(posterPath), in: cacheDirectory)
    }

    return imageData
  }
}

/// Saved provider identity and poster path used by one explicit artwork repair.
struct SavedPosterDecision {
  /// Provider movie ID established by an earlier confirmed decision.
  let movieID: Int
  /// Provider path for the source artwork.
  let posterPath: String
  /// Saved processing evidence, including the identity source.
  let record: FolderRecord
  /// Metadata passed through existing recoverable failure recording.
  var movie: MovieMetadata {
    MovieMetadata(
      id: movieID, title: record.movieTitle ?? "", originalTitle: record.movieTitle ?? "",
      releaseYear: record.movieYear, posterPath: posterPath)
  }
}

/// Folder and root authority held while repairing one saved poster decision.
struct ArtworkRepairContext {
  /// Immediate child whose identity must remain unchanged.
  let candidate: FolderCandidate
  /// Authorized collection directory containing the child.
  let root: URL
  /// Held persistence lease for this root.
  let lease: PersistenceLease
}
