import CryptoKit
import FileSystem
import Foundation
import ImageIO
import MovieFolderParsing
import Network
import Persistence

extension MovieFolderProcessor {
  /// Stores an unresolved outcome with the conservative retry delay.
  ///
  /// - Parameters:
  ///   - candidate: The child folder evidence captured before this operation.
  ///   - state: The root processing state being inspected or updated.
  func recordUnresolved(
    _ candidate: FolderCandidate, in state: inout ProcessingState,
    reason: FolderProcessingReason = .parsingProblem, movie: MovieMetadata? = .none
  ) {
    var record = FolderRecord(
      fingerprint: candidate.fingerprint,
      status: .unresolved,
      retryDate: reason == .incompleteSearch
        ? now().addingTimeInterval(configuration.incompleteSearchRetryInterval) : .none,
      matchedMovieID: movie?.id,
      posterPath: movie?.posterPath,
      processingReason: reason,
      movieTitle: movie?.title,
      movieYear: movie?.releaseYear,
      movieIdentitySource: movie == .none ? .none : .conservativeMatch
    )
    record.nameParserRevision = ReleaseNameParser.revision
    state.folders[candidate.name] = record
  }

  /// Stores a recoverable failure with its shorter retry delay.
  ///
  /// - Parameters:
  ///   - candidate: The child folder evidence captured before this operation.
  ///   - state: The root processing state being inspected or updated.
  func recordTransientFailure(
    _ candidate: FolderCandidate, in state: inout ProcessingState,
    stage: FolderProcessingStage = .unknown, movie: MovieMetadata? = .none,
    reason: FolderProcessingReason? = .none, failureReason: FolderProcessingFailureReason = .unavailable
  ) {
    state.folders[candidate.name] = FolderRecord(
      fingerprint: candidate.fingerprint,
      status: .transientFailure,
      retryDate: reason == .authentication
        ? .none : now().addingTimeInterval(configuration.transientFailureRetryInterval),
      matchedMovieID: movie?.id,
      posterPath: movie?.posterPath,
      processingReason: reason ??
        (stage == .search ? .metadataFailure : (stage == .artwork ? .posterFailure : .processingFailure)),
      movieTitle: movie?.title,
      movieYear: movie?.releaseYear,
      lastFailure: FolderProcessingFailure(reason: failureReason, stage: stage, occurredAt: now()),
      movieIdentitySource: movie == .none ? .none : .conservativeMatch
    )
  }

  /// Decodes root processing state or supplies empty state when no record exists.
  ///
  /// - Parameter lease: The already-held persistence lease used throughout this operation.
  /// - Returns: The decoded root state, or empty state when no record has been saved.
  /// - Throws: Persistence, authorization, changed-folder, or icon-operation errors from the required processing step.
  func loadState(from lease: PersistenceLease) throws -> ProcessingState {
    guard let data = try lease.read() else { return ProcessingState() }

    var state = try JSONDecoder().decode(ProcessingState.self, from: data)
    state.reconcileCredentialRevision(credentialRevision)

    return state
  }

  /// Keeps a verified icon outcome distinct from failure to persist its operational cache.
  func saveAssignedState(
    _ state: ProcessingState, to lease: PersistenceLease, candidate: FolderCandidate,
    root: URL, processingState: inout CollectionProcessingState?
  ) throws {
    do {
      try saveState(state, to: lease)
    } catch {
      if processingState != .none {
        var record = try assessFolderProcessing(candidate, root: root, saved: state.folders[candidate.name])
        record.reason = .cachePersistenceFailure
        record.lastFailure = FolderProcessingFailure(reason: .storage, stage: .persist, occurredAt: now())
        try recordFolderProcessing(record, in: &processingState)
        try finishProcessingOperation(&processingState, state: .failed)
      }
      throw error
    }
    if processingState != .none {
      let record = try assessFolderProcessing(candidate, root: root, saved: state.folders[candidate.name])
      try recordFolderProcessing(record, in: &processingState)
    }
  }

  /// Atomically writes deterministically encoded root processing state.
  ///
  /// - Parameters:
  ///   - state: The root processing state being inspected or updated.
  ///   - lease: The already-held persistence lease used throughout this operation.
  /// - Throws: Persistence, authorization, changed-folder, or icon-operation errors from the required processing step.
  func saveState(_ state: ProcessingState, to lease: PersistenceLease) throws {
    var state = state
    state.credentialRevision = credentialRevision
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    do {
      try lease.write(encoder.encode(state))
    } catch {
      // A recorded operation must stop before another mutation if its operational cache cannot commit.
      if processingStore != nil { throw CollectionProcessingError.unavailable }
      throw error
    }
  }

  /// Returns source image bytes only when the cached file still decodes as a complete image.
  ///
  /// - Parameter path: The provider-relative source poster path.
  /// - Returns: The validated cached bytes when available.
  func cachedPoster(for path: String) -> Data? {
    let name = Self.posterCacheName(path)
    guard let data = try? fileSystem.readData(named: name, in: cacheDirectory),
      Self.isValidPoster(data)
    else { return .none }

    return data
  }

  /// Selects a bounded provider-wide retry boundary for authentication or rate-limit errors.
  ///
  /// - Parameter error: The failure whose retry or test behavior is being selected.
  /// - Returns: The retry boundary when the error requires root backoff.
  func rootBackoff(for error: TMDbError) -> Date? {
    switch error {
    case .rateLimited(let retryAfter):
      let interval = retryInterval(from: retryAfter, now: now())

      return now().addingTimeInterval(interval)
    case .httpStatus(429):
      return now().addingTimeInterval(configuration.transientFailureRetryInterval)
    default:
      return .none
    }
  }

  /// Uses shared validated throttling evidence so a later short response cannot shorten another process's delay.
  /// - Parameter error: The provider failure establishing root-local throttling evidence.
  /// - Returns: The shared deadline, or a finite local fallback for isolated callers.
  /// - Throws: A safe recovery-state error if an injected shared service becomes unreadable.
  func effectiveRootBackoff(for error: TMDbError) throws -> Date? {
    guard let fallback = rootBackoff(for: error) else { return .none }

    return try recovery?.read().providerRetryAt ?? fallback
  }

  /// Parses seconds or an HTTP date and clamps the provider retry interval to supported bounds.
  ///
  /// - Parameters:
  ///   - retryAfter: The provider Retry-After value in seconds or HTTP-date form.
  ///   - now: The clock used for retry and cache expiry decisions.
  /// - Returns: The bounded delay in seconds.
  private func retryInterval(from retryAfter: String?, now: Date) -> TimeInterval {
    let requested: TimeInterval?
    if let retryAfter, let seconds = TimeInterval(retryAfter) {
      requested = seconds
    } else if let retryAfter {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
      requested = formatter.date(from: retryAfter)?.timeIntervalSince(now)
    } else {
      requested = .none
    }

    let finite = requested.flatMap { $0.isFinite ? $0 : .none }
      ?? configuration.transientFailureRetryInterval

    return min(
      max(finite, configuration.minimumProviderRetryInterval),
      configuration.maximumProviderRetryInterval)
  }

  /// Hashes the normalized title/year pair into a filesystem-independent cache key.
  ///
  /// - Parameters:
  ///   - title: The movie title used for search or exact normalized comparison.
  ///   - year: The release year when available; no value preserves year uncertainty.
  /// - Returns: The SHA-256 cache key for this title and optional release year.
  static func queryKey(title: String, year: Int?) -> String {
    digest("\(title.lowercased())|\(year.map(String.init) ?? "")")
  }

  /// Hashes the provider poster path into a bounded cache filename.
  ///
  /// - Parameter path: The provider-relative source poster path.
  /// - Returns: The poster cache filename derived from the provider path digest.
  static func posterCacheName(_ path: String) -> String { "poster-\(digest(path))" }

  /// Encodes a UTF-8 input as a lowercase SHA-256 digest.
  ///
  /// - Parameter value: The query or provider poster path to encode as a stable digest.
  /// - Returns: The lowercase hexadecimal SHA-256 digest of the UTF-8 input.
  static func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// Requires complete image data that ImageIO can decode into a thumbnail.
  ///
  /// - Parameter data: The encoded record or image bytes consumed by this operation.
  /// - Returns: Whether the bytes contain a complete image that ImageIO can decode into a thumbnail.
  static func isValidPoster(_ data: Data) -> Bool {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
    guard CGImageSourceGetStatus(source) == .statusComplete,
      CGImageSourceGetCount(source) > 0,
      CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
    else { return false }

    return CGImageSourceCreateThumbnailAtIndex(
      source, 0,
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 512
      ] as CFDictionary) != nil
  }
}
