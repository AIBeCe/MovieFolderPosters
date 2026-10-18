import CryptoKit
import FileSystem
import Foundation
import ImageIO
import Network
import Persistence

/// Supplies movie search results and source poster bytes to the processing pipeline.
nonisolated public protocol MovieMetadataProvider: Sendable {
  /// Searches the provider for candidate movies without assuming result order implies identity.
  ///
  /// - Parameters:
  ///   - title: The movie title used for search or exact normalized comparison.
  ///   - year: The release year when available; no value preserves year uncertainty.
  /// - Returns: Provider candidates and evidence indicating whether more pages remain.
  /// - Throws: Provider, transport, decoding, or cancellation errors.
  func searchMovies(title: String, year: Int?) async throws -> MovieSearchResult
  /// Downloads the source image bytes for a provider-relative poster path.
  ///
  /// - Parameter path: The provider-relative source poster path.
  /// - Returns: The downloaded source image bytes; decoding is validated by the processing caller.
  /// - Throws: Provider, transport, image-response, or cancellation errors.
  func downloadPoster(path: String) async throws -> Data
}

nonisolated extension TMDbClient: MovieMetadataProvider {}

/// Assigns a poster while preserving existing icons and checking expected folder identity.
nonisolated public protocol PosterAssigner: Sendable {
  /// Assigns source image bytes while checking child identity and preserving a foreign custom icon.
  ///
  /// - Parameters:
  ///   - imageData: Complete source poster image bytes.
  ///   - name: The immediate child folder name.
  ///   - directory: The authorized collection root.
  ///   - expectedIdentity: The filesystem identity captured when the operation was authorized.
  /// - Returns: Whether the poster was assigned or an existing icon was preserved.
  /// - Throws: Filesystem, image-decoding, or identity validation errors from the icon adapter.
  func assignPoster(
    _ imageData: Data,
    toChild name: String,
    in directory: URL,
    expectedIdentity: String?
  ) throws -> PosterAssignmentResult

  /// Assigns source image bytes while checking child identity and preserving a foreign custom icon.
  ///
  /// - Parameters:
  ///   - imageData: Complete source poster image bytes.
  ///   - name: The immediate child folder name.
  ///   - directory: The authorized collection root.
  ///   - appearance: The rendering finish selected for the assigned poster.
  ///   - expectedIdentity: The filesystem identity captured when the operation was authorized.
  /// - Returns: Whether the poster was assigned or an existing icon was preserved.
  /// - Throws: Filesystem, image-decoding, or identity validation errors from the icon adapter.
  func assignPoster(
    _ imageData: Data,
    toChild name: String,
    in directory: URL,
    appearance: PosterAppearance,
    expectedIdentity: String?
  ) throws -> PosterAssignmentResult
}

nonisolated public extension PosterAssigner {
  /// Adapts legacy assigners by forwarding the identity check without applying the appearance argument.
  ///
  /// - Parameters:
  ///   - imageData: Complete source poster image bytes.
  ///   - name: The immediate child folder name.
  ///   - directory: The authorized collection root.
  ///   - appearance: The rendering finish selected for the assigned poster.
  ///   - expectedIdentity: The filesystem identity captured when the operation was authorized.
  /// - Returns: Whether the poster was assigned or an existing icon was preserved.
  /// - Throws: Filesystem, image-decoding, or identity validation errors from the icon adapter.
  func assignPoster(
    _ imageData: Data,
    toChild name: String,
    in directory: URL,
    appearance: PosterAppearance,
    expectedIdentity: String?
  ) throws -> PosterAssignmentResult {
    try assignPoster(imageData, toChild: name, in: directory, expectedIdentity: expectedIdentity)
  }
}

nonisolated extension FileSystemService: PosterAssigner {}

/// Failures that prevent a root from being inspected for automatic processing.
nonisolated public enum ProcessingError: Error, Equatable {
  case unavailableRoot
}

/// Recoverable validation, ownership, matching, and contention failures for manual actions.
nonisolated public enum PosterActionError: Error, Equatable {
  case busy
  case unresolved
  case foreignIcon
  case changedIdentity
  case noPoster
}

/// Outcomes from one processing visit, including work skipped by safety and retry checks.
nonisolated public struct ProcessingSummary: Equatable, Sendable {
  /// Folders for which this visit attempted to establish a movie match.
  public var examined: Int
  /// Poster assignments completed during this visit.
  public var assigned: Int
  /// Owned posters rewritten from cache using the selected appearance.
  public var restyled: Int
  /// Folders that could not be parsed or uniquely matched during this visit.
  public var unresolved: Int
  /// Recoverable folder operations that failed during this visit.
  public var transientFailures: Int
  /// Folders whose existing custom icon was preserved.
  public var skippedExistingIcons: Int
  /// Previously completed folders skipped without another assignment.
  public var skippedPreviouslyProcessed: Int
  /// Folders deferred until their saved retry time.
  public var skippedRetryWindow: Int
  /// Whether another operation already held the collection processing lease.
  public var rootLeaseUnavailable: Bool
  /// The provider-wide retry boundary saved for this root, when present.
  public var rootBackoffUntil: Date?

  /// Creates visit counts and retry evidence; omitted counts begin at zero.
  ///
  /// - Parameters:
  ///   - examined: The number of folders examined for a movie match.
  ///   - assigned: The number of poster assignments completed.
  ///   - restyled: The number of owned posters restyled from cache.
  ///   - unresolved: The number of folders without a confident movie match.
  ///   - transientFailures: The number of recoverable folder failures.
  ///   - skippedExistingIcons: The number of preserved custom icons.
  ///   - skippedPreviouslyProcessed: The number of previously completed folders skipped.
  ///   - skippedRetryWindow: The number of folders deferred by retry state.
  ///   - rootLeaseUnavailable: Whether a competing operation prevented the root visit.
  ///   - rootBackoffUntil: The provider-wide retry boundary, if present.
  public init(
    examined: Int = 0,
    assigned: Int = 0,
    restyled: Int = 0,
    unresolved: Int = 0,
    transientFailures: Int = 0,
    skippedExistingIcons: Int = 0,
    skippedPreviouslyProcessed: Int = 0,
    skippedRetryWindow: Int = 0,
    rootLeaseUnavailable: Bool = false,
    rootBackoffUntil: Date? = nil
  ) {
    self.examined = examined
    self.assigned = assigned
    self.restyled = restyled
    self.unresolved = unresolved
    self.transientFailures = transientFailures
    self.skippedExistingIcons = skippedExistingIcons
    self.skippedPreviouslyProcessed = skippedPreviouslyProcessed
    self.skippedRetryWindow = skippedRetryWindow
    self.rootLeaseUnavailable = rootLeaseUnavailable
    self.rootBackoffUntil = rootBackoffUntil
  }
}

/// Revalidates current authorization before mutations and optionally holds a settings lease.
nonisolated public protocol MovieFolderMutationGuard: Sendable {
  /// Revalidates authorization immediately before an automatic mutation.
  ///
  /// - Parameters:
  ///   - processor: The processor requesting authorization for its next mutation.
  ///   - root: The authorized collection directory containing the immediate child.
  /// - Returns: A lease held through mutation, or no lease when no retained lock is needed.
  /// - Throws: A live configuration, authorization, persistence, or root identity validation failure.
  func movieFolderProcessor(_ processor: MovieFolderProcessor, willPerformAutomaticMutationIn root: URL)
    throws -> PersistenceLease?
  /// Revalidates authorization immediately before a manual mutation.
  ///
  /// - Parameter processor: The processor requesting authorization for its next mutation.
  /// - Returns: A lease to retain through the write, or no lease when validation needs no retained lock.
  /// - Throws: Persistence, authorization, changed-folder, or icon-operation errors from the required processing step.
  func movieFolderProcessorWillPerformManualMutation(_ processor: MovieFolderProcessor) throws -> PersistenceLease?
}

/// Serializes movie-folder processing, caches results, and validates identity before icon writes.
public actor MovieFolderProcessor {
  /// How long an unresolved folder waits before automatic matching is retried.
  private static let unresolvedRetryInterval: TimeInterval = 24 * 60 * 60
  /// The default retry delay following a recoverable provider or processing failure.
  private static let transientRetryInterval: TimeInterval = 10 * 60
  /// How long a complete or incomplete search response remains reusable.
  private static let queryCacheLifetime: TimeInterval = 24 * 60 * 60
  /// The lower bound accepted for a provider retry delay.
  private static let minimumRateLimitInterval: TimeInterval = 60
  /// The upper bound accepted for provider and authentication backoff.
  private static let maximumRateLimitInterval: TimeInterval = 24 * 60 * 60

  /// The adapter used for directory evidence, cache access, and owned-icon operations.
  private let fileSystem: FileSystemService
  /// The store holding this root generation's processing records.
  private let persistence: PersistenceStore
  /// Optional stable locks shared across processing-record generations.
  private let coordinationStore: PersistenceStore?
  /// The metadata source used only when cached decisions or posters are insufficient.
  private let provider: any MovieMetadataProvider
  /// The directory containing validated source poster bytes keyed by provider path.
  private let cacheDirectory: URL
  /// The adapter performing automatic poster assignment after identity checks.
  private let posterAssigner: any PosterAssigner
  /// The clock used to evaluate cache age and retry boundaries.
  private let now: @Sendable () -> Date
  /// The retained collaborator that must approve configured mutation boundaries.
  private let mutationGuard: (any MovieFolderMutationGuard)?
  /// The selected finish used for poster rendering.
  private let appearance: PosterAppearance
  /// Commits authoritative results independently of operational caches.
  private let processingStore: CollectionProcessingStore?
  /// The conservative folder-name parser used before metadata searches.
  private let parser = ReleaseNameParser()
  /// The conservative movie matcher used after a complete provider response.
  private let matcher = MovieMatcher()

  /// Connects the processing stores, metadata source, clock, icon adapter, and optional mutation guard.
  ///
  /// - Parameters:
  ///   - fileSystem: The filesystem adapter used for evidence, cache, and icon operations.
  ///   - persistence: The per-generation store of folder decisions and query results.
  ///   - provider: The source of movie metadata and poster images.
  ///   - cacheDirectory: The directory used for validated source image caching.
  ///   - posterAssigner: The synchronous adapter performing final automatic icon assignment.
  ///   - now: The clock used for retry and cache expiry decisions.
  ///   - coordinationStore: Optional stable locks shared across processing generations.
  ///   - mutationGuard: Optional retained collaborator enforcing live settings authorization.
  ///   - appearance: The rendering finish selected for the assigned poster.
  ///   - processingStore: Dedicated result storage; production supplies it with a current context for each operation.
  public init(
    fileSystem: FileSystemService = FileSystemService(),
    persistence: PersistenceStore,
    provider: any MovieMetadataProvider,
    cacheDirectory: URL,
    posterAssigner: any PosterAssigner = FileSystemService(),
    now: @escaping @Sendable () -> Date = Date.init,
    coordinationStore: PersistenceStore? = nil,
    mutationGuard: (any MovieFolderMutationGuard)? = nil,
    appearance: PosterAppearance = .softFinish,
    processingStore: CollectionProcessingStore? = nil
  ) {
    self.fileSystem = fileSystem
    self.persistence = persistence
    self.coordinationStore = coordinationStore
    self.provider = provider
    self.cacheDirectory = cacheDirectory
    self.posterAssigner = posterAssigner
    self.now = now
    self.mutationGuard = mutationGuard
    self.appearance = appearance
    self.processingStore = processingStore
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
    root: URL, processingContext: CollectionProcessingContext? = nil
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
    var processingState = try recordProcessingStart(context: processingContext, action: .automatic)
    defer { interruptUnfinishedProcessing(&processingState) }
    let candidates: [FolderCandidate]
    do {
      if processingState != nil {
        let inventory = try fileSystem.inventory(in: root)
        guard inventory.members.count <= 10_000 else {
          processingState?.inventoryIssue = .capacityExceeded
          throw CollectionProcessingError.capacityExceeded
        }
        processingState?.folders = inventory.members.map {
          FolderProcessingRecord(
            name: $0.name, identity: $0.identity,
            state: $0.candidate == nil ? .failed : .pending,
            reason: $0.candidate == nil ? .inspectionFailure : .inventoryPending,
            assessedAt: $0.candidate == nil ? now() : nil,
            fingerprint: $0.candidate?.fingerprint)
        }
        processingState?.isInventoryComplete = inventory.isComplete
        processingState?.inspectedAt = now()
        processingState?.inventoryIssue = inventory.isComplete ? nil : .inspectionFailure
        try commitProcessingState(&processingState)
        // An incomplete type inventory cannot authorize a fabricated population or new writes.
        guard inventory.isComplete else { throw ProcessingError.unavailableRoot }
        candidates = inventory.members.compactMap(\.candidate)
      } else {
        candidates = try fileSystem.candidates(in: root)
      }
    } catch let error as CollectionProcessingError {
      throw error
    } catch {
      throw ProcessingError.unavailableRoot
    }

    var state = try loadState(from: lease)
    let currentTime = now()
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
    var summary = ProcessingSummary()
    for candidate in candidates where candidate.hasCustomIcon {
      try Task.checkCancellation()
      do {
        if try restyleOwnedPosterIfPossible(candidate, in: root, state: state) {
          summary.restyled += 1
        } else {
          summary.skippedExistingIcons += 1
        }
        try recordFolderProcessing(
          assessFolderProcessing(candidate, root: root, saved: state.folders[candidate.name]), in: &processingState)
      } catch let error as CollectionProcessingError {
        throw error
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if Task.isCancelled { throw CancellationError() }
        summary.transientFailures += 1
        if processingState != nil {
          var record = (try? assessFolderProcessing(candidate, root: root, saved: state.folders[candidate.name]))
            ?? failedFolderAssessment(candidate, stage: .validateIdentity)
          record.lastFailure = FolderProcessingFailure(reason: .filesystem, stage: .assignPoster, occurredAt: now())
          if record.state != .done { record.reason = .filesystemFailure }
          try recordFolderProcessing(record, in: &processingState)
        }
      }
    }
    if let backoff = state.rootBackoffUntil, backoff > currentTime {
      if stateChanged { try saveState(state, to: lease) }
      summary.rootBackoffUntil = backoff
      deferPendingFolderAssessments(&processingState, until: backoff)
      try finishProcessingOperation(&processingState, state: .partial)

      return summary
    }
    if state.rootBackoffUntil != nil { stateChanged = true }
    state.rootBackoffUntil = nil
    if stateChanged { try saveState(state, to: lease) }
    for candidate in candidates {
      try Task.checkCancellation()
      do {
        if try fileSystem.isPosterSuppressed(toChild: candidate.name, in: root) {
          if !candidate.hasCustomIcon {
            try recordFolderProcessing(FolderProcessingRecord(
              name: candidate.name, identity: candidate.identity, state: .suppressed,
              reason: .policySuppressed, ownership: .none, assessedAt: now(), fingerprint: candidate.fingerprint),
              in: &processingState)
          }
          continue
        }
      } catch let error as CollectionProcessingError {
        throw error
      } catch {
        summary.transientFailures += 1
        try recordFolderProcessing(failedFolderAssessment(candidate, stage: .validateIdentity), in: &processingState)
        continue
      }
      if candidate.hasCustomIcon {
        continue
      }

      let priorRecord = state.folders[candidate.name]
      let sameFingerprint = priorRecord?.fingerprint == candidate.fingerprint
      if sameFingerprint, let record = priorRecord {
        if record.status == .processed,
          let movieID = record.matchedMovieID,
          let posterPath = record.posterPath,
          let cached = cachedPoster(for: posterPath)
        {
          do {
            let result = try assign(cached, to: candidate, in: root)
            state.folders[candidate.name] = FolderRecord(
              fingerprint: candidate.fingerprint,
              status: .processed,
              retryDate: nil,
              matchedMovieID: movieID,
              posterPath: posterPath,
              movieTitle: record.movieTitle,
              movieYear: record.movieYear,
              movieIdentitySource: record.movieIdentitySource ?? .savedDecision
            )
            try saveAssignedState(state, to: lease, candidate: candidate, root: root, processingState: &processingState)
            if case .assigned = result { summary.assigned += 1 }
          } catch let error as CollectionProcessingError {
            throw error
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            if Task.isCancelled { throw CancellationError() }
            recordTransientFailure(candidate, in: &state)
            try saveState(state, to: lease)
            summary.transientFailures += 1
            try recordFolderProcessing(failedFolderAssessment(candidate, stage: .assignPoster), in: &processingState)
          }
          continue
        }
        if record.status != .processed, let retryDate = record.retryDate, retryDate > now() {
          summary.skippedRetryWindow += 1
          try recordFolderProcessing(cachedFolderAssessment(candidate, saved: record), in: &processingState)
          continue
        }
      }

      summary.examined += 1
      var attemptStage: FolderProcessingStage = .parse
      var identifiedMovie: MovieMetadata?
      do {
        guard case .parsed(let parsed) = parser.parse(candidate.name) else {
          recordUnresolved(candidate, in: &state)
          try saveState(state, to: lease)
          summary.unresolved += 1
          let record = unresolvedFolderAssessment(candidate, reason: .parsingProblem)
          try recordFolderProcessing(record, in: &processingState)
          continue
        }

        attemptStage = .search
        let queryKey = Self.queryKey(title: parsed.title, year: parsed.year)
        let search: MovieSearchResult
        if let cached = state.queries[queryKey],
          now().timeIntervalSince(cached.createdAt) < Self.queryCacheLifetime
        {
          search = cached.searchResult()
        } else {
          search = try await provider.searchMovies(title: parsed.title, year: parsed.year)
          try Task.checkCancellation()
          state.queries[queryKey] = CachedSearch(result: search, createdAt: now())
          try saveState(state, to: lease)
        }

        let identityResult = matcher.identify(title: parsed.title, year: parsed.year, search: search)
        guard case .matched(let movie) = identityResult, let posterPath = movie.posterPath,
          !posterPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          let reason: FolderProcessingReason
          let identifiedMovie: MovieMetadata?
          switch identityResult {
          case .matched(let movie):
            reason = .missingArtwork
            identifiedMovie = movie
          case .unresolved(let issue):
            identifiedMovie = nil
            switch issue {
            case .ambiguous: reason = .ambiguousMovie
            case .noSuitableMatch: reason = .noSuitableMovie
            case .incompleteSearch: reason = .incompleteSearch
            case .missingPoster: reason = .missingArtwork
            case .invalidQuery: reason = .parsingProblem
            }
          }
          recordUnresolved(candidate, in: &state, reason: reason, movie: identifiedMovie)
          try saveState(state, to: lease)
          summary.unresolved += 1
          let record = unresolvedFolderAssessment(candidate, reason: reason, movie: identifiedMovie)
          try recordFolderProcessing(record, in: &processingState)
          continue
        }

        identifiedMovie = movie
        attemptStage = .artwork
        let imageData: Data
        if let cached = cachedPoster(for: posterPath) {
          imageData = cached
        } else {
          imageData = try await provider.downloadPoster(path: posterPath)
          try Task.checkCancellation()
          guard Self.isValidPoster(imageData) else { throw ProcessingFailure.invalidPoster }
          try? fileSystem.writeData(
            imageData, named: Self.posterCacheName(posterPath),
            in: cacheDirectory)
        }

        attemptStage = .assignPoster
        let result = try assign(imageData, to: candidate, in: root)
        state.folders[candidate.name] = FolderRecord(
          fingerprint: candidate.fingerprint,
          status: .processed,
          retryDate: nil,
          matchedMovieID: movie.id,
          posterPath: posterPath,
          movieTitle: movie.title,
          movieYear: movie.releaseYear,
          movieIdentitySource: .conservativeMatch
        )
        try saveAssignedState(state, to: lease, candidate: candidate, root: root, processingState: &processingState)
        if case .assigned = result { summary.assigned += 1 }
      } catch let error as CollectionProcessingError {
        throw error
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as TMDbError {
        if Task.isCancelled { throw CancellationError() }
        if let retryDate = rootBackoff(for: error) {
          state.rootBackoffUntil = retryDate
          try saveState(state, to: lease)
          summary.rootBackoffUntil = retryDate
          var record = failedFolderAssessment(candidate, stage: attemptStage, movie: identifiedMovie)
          record.reason = error == .authentication ? .authentication : .rateLimited
          record.retryAt = retryDate
          try recordFolderProcessing(record, in: &processingState)
          deferPendingFolderAssessments(&processingState, until: retryDate)
          break
        }
        recordTransientFailure(candidate, in: &state, stage: attemptStage, movie: identifiedMovie)
        try saveState(state, to: lease)
        summary.transientFailures += 1
        let record = failedFolderAssessment(candidate, stage: attemptStage, movie: identifiedMovie)
        try recordFolderProcessing(record, in: &processingState)
      } catch {
        if Task.isCancelled { throw CancellationError() }
        recordTransientFailure(candidate, in: &state, stage: attemptStage, movie: identifiedMovie)
        try saveState(state, to: lease)
        summary.transientFailures += 1
        let record = failedFolderAssessment(candidate, stage: attemptStage, movie: identifiedMovie)
        try recordFolderProcessing(record, in: &processingState)
      }
    }
    try finishProcessingOperation(&processingState, state: summary.rootBackoffUntil == nil ? .completed : .partial)

    return summary
  }

  /// Downloads and applies a fresh poster for a saved or newly established movie match.
  ///
  /// - Parameters:
  ///   - root: The authorized collection directory containing the immediate child.
  ///   - child: The immediate child folder name, without additional path components.
  ///   - expectedIdentity: The filesystem identity captured when the operation was authorized.
  ///   - processingContext: Captured current collection generation for durable operation results.
  /// - Returns: The TMDb identifier associated with the applied poster.
  /// - Throws: Cancellation, provider, persistence, ownership, authorization, or changed-identity errors.
  public func refreshPoster(
    root: URL, child: String, expectedIdentity: String, processingContext: CollectionProcessingContext? = nil
  ) async throws -> Int {
    try Task.checkCancellation()
    let coordinationLease = try acquireCoordinationLease(for: root)
    defer { withExtendedLifetime(coordinationLease) {} }
    let lease = try acquireRootLease(for: root)
    defer { withExtendedLifetime(lease) {} }
    var state = try loadState(from: lease)
    var processingState = try recordProcessingStart(context: processingContext, action: .refresh, child: child)
    defer { recoverManualProcessing(&processingState, root: root, child: child, saved: state.folders[child]) }
    var candidate = try actionCandidate(root: root, child: child, expectedIdentity: expectedIdentity)
    try ensureReplaceableIcon(for: candidate, in: root)

    let movieID: Int
    let posterPath: String
    var freshSearch: CachedSearch?
    var movieTitle = state.folders[child]?.movieTitle
    var movieYear = state.folders[child]?.movieYear
    if let record = state.folders[child], record.fingerprint == candidate.fingerprint,
      record.status == .processed, let savedMovieID = record.matchedMovieID,
      let savedPosterPath = record.posterPath
    {
      movieID = savedMovieID
      posterPath = savedPosterPath
    } else {
      guard case .parsed(let parsed) = parser.parse(child) else { throw PosterActionError.unresolved }
      let key = Self.queryKey(title: parsed.title, year: parsed.year)
      let search = try await provider.searchMovies(title: parsed.title, year: parsed.year)
      try Task.checkCancellation()
      candidate = try actionCandidate(root: root, child: child, expectedIdentity: expectedIdentity)
      try ensureReplaceableIcon(for: candidate, in: root)
      freshSearch = CachedSearch(result: search, createdAt: now())
      let match = matcher.match(title: parsed.title, year: parsed.year, search: search)
      guard case .matched(let movie) = match, let matchedPosterPath = movie.posterPath else {
        if match == .unresolved(.missingPoster) { throw PosterActionError.noPoster }
        throw PosterActionError.unresolved
      }
      movieID = movie.id
      movieTitle = movie.title
      movieYear = movie.releaseYear
      posterPath = matchedPosterPath
      if let freshSearch { state.queries[key] = freshSearch }
    }

    let imageData = try await provider.downloadPoster(path: posterPath)
    try Task.checkCancellation()
    guard Self.isValidPoster(imageData) else { throw PosterActionError.noPoster }
    candidate = try actionCandidate(root: root, child: child, expectedIdentity: expectedIdentity)
    try ensureReplaceableIcon(for: candidate, in: root)
    do {
      let settingsLease = try mutationGuard?.movieFolderProcessorWillPerformManualMutation(self)
      defer { withExtendedLifetime(settingsLease) {} }
      try replacePoster(imageData, candidate: candidate, root: root)
    }
    try? fileSystem.writeData(imageData, named: Self.posterCacheName(posterPath), in: cacheDirectory)
    var refreshedRecord = processedRecord(for: candidate, movieID: movieID, posterPath: posterPath)
    refreshedRecord.movieTitle = movieTitle
    refreshedRecord.movieYear = movieYear
    refreshedRecord.movieIdentitySource = state.folders[child]?.movieIdentitySource ?? .savedDecision
    state.folders[child] = refreshedRecord
    state.rootBackoffUntil = nil
    do {
      try saveState(state, to: lease)
    } catch {
      if processingState != nil {
        var record = try assessFolderProcessing(candidate, root: root, saved: state.folders[child])
        record.lastFailure = FolderProcessingFailure(reason: .storage, stage: .persist, occurredAt: now())
        record.reason = .cachePersistenceFailure
        try recordFolderProcessing(record, in: &processingState)
        try finishProcessingOperation(&processingState, state: .failed)
      }
      throw error
    }
    if processingState != nil {
      let record = try assessFolderProcessing(candidate, root: root, saved: state.folders[child])
      try recordFolderProcessing(record, in: &processingState)
      try finishProcessingOperation(&processingState, state: .completed)
    }

    return movieID
  }

  /// Applies an explicitly selected movie and records that choice for later refreshes.
  ///
  /// - Parameters:
  ///   - movie: The explicit provider movie record to retain or apply.
  ///   - root: The authorized collection directory containing the immediate child.
  ///   - child: The immediate child folder name, without additional path components.
  ///   - expectedIdentity: The filesystem identity captured when the operation was authorized.
  ///   - processingContext: Captured current collection generation for durable operation results.
  /// - Returns: The selected TMDb identifier after its poster and decision are saved.
  /// - Throws: Cancellation, provider, persistence, ownership, authorization, or changed-identity errors.
  public func applyMoviePoster(
    _ movie: MovieMetadata, root: URL, child: String, expectedIdentity: String,
    processingContext: CollectionProcessingContext? = nil
  ) async throws -> Int {
    try Task.checkCancellation()
    let coordinationLease = try acquireCoordinationLease(for: root)
    defer { withExtendedLifetime(coordinationLease) {} }
    let lease = try acquireRootLease(for: root)
    defer { withExtendedLifetime(lease) {} }
    var state = try loadState(from: lease)
    var processingState = try recordProcessingStart(context: processingContext, action: .selection, child: child)
    defer { recoverManualProcessing(&processingState, root: root, child: child, saved: state.folders[child]) }
    guard movie.id > 0 else { throw PosterActionError.unresolved }
    guard let posterPath = movie.posterPath,
      !posterPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw PosterActionError.noPoster
    }
    var candidate = try actionCandidate(root: root, child: child, expectedIdentity: expectedIdentity)
    try ensureReplaceableIcon(for: candidate, in: root)
    let imageData = try await provider.downloadPoster(path: posterPath)
    try Task.checkCancellation()
    guard Self.isValidPoster(imageData) else { throw PosterActionError.noPoster }
    candidate = try actionCandidate(root: root, child: child, expectedIdentity: expectedIdentity)
    try ensureReplaceableIcon(for: candidate, in: root)
    do {
      let settingsLease = try mutationGuard?.movieFolderProcessorWillPerformManualMutation(self)
      defer { withExtendedLifetime(settingsLease) {} }
      try replacePoster(imageData, candidate: candidate, root: root)
    }
    try? fileSystem.writeData(imageData, named: Self.posterCacheName(posterPath), in: cacheDirectory)
    var selectedRecord = processedRecord(for: candidate, movieID: movie.id, posterPath: posterPath)
    selectedRecord.movieTitle = movie.title
    selectedRecord.movieYear = movie.releaseYear
    selectedRecord.movieIdentitySource = .explicitSelection
    state.folders[child] = selectedRecord
    state.rootBackoffUntil = nil
    do {
      try saveState(state, to: lease)
    } catch {
      if processingState != nil {
        var record = try assessFolderProcessing(candidate, root: root, saved: state.folders[child])
        record.lastFailure = FolderProcessingFailure(reason: .storage, stage: .persist, occurredAt: now())
        record.reason = .cachePersistenceFailure
        try recordFolderProcessing(record, in: &processingState)
        try finishProcessingOperation(&processingState, state: .failed)
      }
      throw error
    }
    if processingState != nil {
      let record = try assessFolderProcessing(candidate, root: root, saved: state.folders[child])
      try recordFolderProcessing(record, in: &processingState)
      try finishProcessingOperation(&processingState, state: .completed)
    }

    return movie.id
  }

  /// Removes an owned poster and suppresses automatic recreation.
  ///
  /// - Parameters:
  ///   - root: The authorized collection directory containing the immediate child.
  ///   - child: The immediate child folder name, without additional path components.
  ///   - expectedIdentity: The filesystem identity captured when the operation was authorized.
  ///   - processingContext: Captured current collection generation for durable operation results.
  /// - Returns: Whether an owned poster was actually removed.
  /// - Throws: Contention, persistence, authorization, ownership, or changed-identity errors.
  public func removePoster(
    root: URL, child: String, expectedIdentity: String, processingContext: CollectionProcessingContext? = nil
  ) throws -> Bool {
    let coordinationLease = try acquireCoordinationLease(for: root)
    defer { withExtendedLifetime(coordinationLease) {} }
    let lease = try acquireRootLease(for: root)
    defer { withExtendedLifetime(lease) {} }
    var state = try loadState(from: lease)
    var processingState = try recordProcessingStart(context: processingContext, action: .removal, child: child)
    defer { recoverManualProcessing(&processingState, root: root, child: child, saved: state.folders[child]) }
    let candidate = try actionCandidate(root: root, child: child, expectedIdentity: expectedIdentity)
    let isOwned: Bool
    do {
      isOwned = try fileSystem.hasAssignedPoster(
        toChild: child, in: root, expectedIdentity: expectedIdentity
      )
    } catch let error as FolderPosterError {
      if case .invalidChild = error { throw PosterActionError.changedIdentity }
      throw error
    }
    guard isOwned else {
      if candidate.hasCustomIcon { throw PosterActionError.foreignIcon }

      if processingState != nil {
        let record = try assessFolderProcessing(candidate, root: root, saved: state.folders[child])
        try recordFolderProcessing(record, in: &processingState)
        try finishProcessingOperation(&processingState, state: .completed)
      }
      return false
    }
    try Task.checkCancellation()
    let removed: Bool
    do {
      let settingsLease = try mutationGuard?.movieFolderProcessorWillPerformManualMutation(self)
      defer { withExtendedLifetime(settingsLease) {} }
      removed = try fileSystem.removeAssignedPoster(
        toChild: child, in: root, expectedIdentity: expectedIdentity
      )
    } catch let error as FolderPosterError {
      if case .invalidChild = error { throw PosterActionError.changedIdentity }
      throw error
    }
    guard removed else { return false }
    state.folders.removeValue(forKey: child)
    do {
      try saveState(state, to: lease)
    } catch {
      if processingState != nil {
        var record = try assessFolderProcessing(candidate, root: root, saved: nil)
        record.reason = .cachePersistenceFailure
        record.lastFailure = FolderProcessingFailure(reason: .storage, stage: .persist, occurredAt: now())
        try recordFolderProcessing(record, in: &processingState)
        try finishProcessingOperation(&processingState, state: .failed)
      }
      throw error
    }
    if processingState != nil {
      try recordFolderProcessing(assessFolderProcessing(candidate, root: root, saved: nil), in: &processingState)
      try finishProcessingOperation(&processingState, state: .completed)
    }

    return true
  }

  /// Reads the recorded match only if the requested folder still has the expected identity.
  ///
  /// - Parameters:
  ///   - root: The authorized collection directory containing the immediate child.
  ///   - child: The immediate child folder name, without additional path components.
  ///   - expectedIdentity: The filesystem identity captured when the operation was authorized.
  /// - Returns: The saved TMDb identifier, or no value if no current processed match exists.
  /// - Throws: Contention, persistence, or changed-identity errors.
  public func matchedMovieID(root: URL, child: String, expectedIdentity: String) throws -> Int? {
    let coordinationLease = try acquireCoordinationLease(for: root)
    defer { withExtendedLifetime(coordinationLease) {} }
    let lease = try acquireRootLease(for: root)
    defer { withExtendedLifetime(lease) {} }
    let candidate = try actionCandidate(root: root, child: child, expectedIdentity: expectedIdentity)
    guard let record = try loadState(from: lease).folders[child],
      record.fingerprint == candidate.fingerprint, record.status == .processed
    else { return nil }

    return record.matchedMovieID
  }

  /// Acquires the root processing lease or reports contention.
  ///
  /// - Parameter root: The authorized collection directory containing the immediate child.
  /// - Returns: The held persistence lease.
  /// - Throws: Persistence, authorization, changed-folder, or icon-operation errors from the required processing step.
  private func acquireRootLease(for root: URL) throws -> PersistenceLease {
    guard let lease = try persistence.acquireLease(for: Self.rootLeaseKey(for: root)) else {
      throw PosterActionError.busy
    }

    return lease
  }

  /// Acquires the optional stable root lock shared by different settings generations.
  ///
  /// - Parameter root: The authorized collection directory containing the immediate child.
  /// - Returns: The held lease when coordination is configured.
  /// - Throws: Persistence, authorization, changed-folder, or icon-operation errors from the required processing step.
  private func acquireCoordinationLease(for root: URL) throws -> PersistenceLease? {
    guard let coordinationStore else { return nil }
    guard let lease = try coordinationStore.acquireLease(for: Self.rootCoordinationKey(for: root)) else {
      throw PosterActionError.busy
    }

    return lease
  }

  /// Reads the immediate child and rejects identity changes before a manual action.
  ///
  /// - Parameters:
  ///   - root: The authorized collection directory containing the immediate child.
  ///   - child: The immediate child folder name, without additional path components.
  ///   - expectedIdentity: The filesystem identity captured when the operation was authorized.
  /// - Returns: The current child evidence after identity validation.
  /// - Throws: Persistence, authorization, changed-folder, or icon-operation errors from the required processing step.
  private func actionCandidate(root: URL, child: String, expectedIdentity: String) throws -> FolderCandidate {
    let candidate: FolderCandidate
    do {
      candidate = try fileSystem.readCurrentState(ofChild: child, in: root)
    } catch {
      throw PosterActionError.changedIdentity
    }
    guard candidate.identity == expectedIdentity else { throw PosterActionError.changedIdentity }

    return candidate
  }

  /// Rejects foreign icons while allowing replacement of an owned poster.
  ///
  /// - Parameters:
  ///   - candidate: The child folder evidence captured before this operation.
  ///   - root: The authorized collection directory containing the immediate child.
  /// - Throws: Persistence, authorization, changed-folder, or icon-operation errors from the required processing step.
  private func ensureReplaceableIcon(for candidate: FolderCandidate, in root: URL) throws {
    let owned: Bool
    do {
      owned = try fileSystem.hasAssignedPoster(
        toChild: candidate.name, in: root, expectedIdentity: candidate.identity
      )
    } catch let error as FolderPosterError {
      if case .invalidChild = error { throw PosterActionError.changedIdentity }
      throw error
    }
    if candidate.hasCustomIcon && !owned { throw PosterActionError.foreignIcon }
  }

  /// Replaces an owned poster and translates changed-child failures for manual actions.
  ///
  /// - Parameters:
  ///   - data: The encoded record or image bytes consumed by this operation.
  ///   - candidate: The child folder evidence captured before this operation.
  ///   - root: The authorized collection directory containing the immediate child.
  /// - Throws: Persistence, authorization, changed-folder, or icon-operation errors from the required processing step.
  private func replacePoster(_ data: Data, candidate: FolderCandidate, root: URL) throws {
    try Task.checkCancellation()
    let result: PosterAssignmentResult
    do {
      result = try fileSystem.replaceAssignedPoster(
        data, toChild: candidate.name, in: root, appearance: appearance,
        expectedIdentity: candidate.identity
      )
    } catch let error as FolderPosterError {
      if case .invalidChild = error { throw PosterActionError.changedIdentity }
      throw error
    }
    if case .existingIconPreserved = result { throw PosterActionError.foreignIcon }
  }

  /// Builds a completed folder record tied to the current identity fingerprint.
  ///
  /// - Parameters:
  ///   - candidate: The child folder evidence captured before this operation.
  ///   - movieID: The TMDb movie identifier retained with the processing record.
  ///   - posterPath: The provider-relative source poster path.
  /// - Returns: A completed decision recording this folder fingerprint and selected movie/poster.
  private func processedRecord(for candidate: FolderCandidate, movieID: Int, posterPath: String) -> FolderRecord {
    FolderRecord(
      fingerprint: candidate.fingerprint, status: .processed, retryDate: nil,
      matchedMovieID: movieID, posterPath: posterPath)
  }

  /// Derives the processing-state lease key from the canonical root path.
  ///
  /// - Parameter root: The authorized collection directory containing the immediate child.
  /// - Returns: The processing lease key namespaced by the canonical root path.
  private static func rootLeaseKey(for root: URL) -> String {
    let canonicalPath = root.resolvingSymlinksInPath().standardizedFileURL.path

    return "movie-folder-processing:\(canonicalPath)"
  }

  /// Derives the stable coordination key from the canonical root path.
  ///
  /// - Parameter root: The authorized collection directory containing the immediate child.
  /// - Returns: The stable coordination key namespaced by the canonical root path.
  private static func rootCoordinationKey(for root: URL) -> String {
    CollectionProcessingStore.coordinationKey(for: root)
  }

  // MARK: - Authoritative result recording
  /// Starts a recorded operation only when production supplied both its store and current context.
  private func recordProcessingStart(
    context: CollectionProcessingContext?, action: CollectionProcessingAction, child: String? = nil
  ) throws -> CollectionProcessingState? {
    guard let processingStore else { return nil }
    guard let context else { throw CollectionProcessingError.configurationChanged }

    return try processingStore.recordProcessingStart(context: context, action: action, child: child, now: now())
  }

  /// Commits a complete revision while preserving the caller's expected operation and revision.
  private func commitProcessingState(_ processingState: inout CollectionProcessingState?) throws {
    guard let processingStore, let current = processingState else { return }
    do {
      processingState = try processingStore.commit(current, expectedRevision: current.revision)
    } catch let error as CollectionProcessingError {
      throw error
    } catch {
      // Storage errors must escape folder recovery before any subsequent icon mutation.
      throw CollectionProcessingError.unavailable
    }
  }

  /// Marks unfinished work conservatively when cancellation or an error exits the operation.
  private func interruptUnfinishedProcessing(_ processingState: inout CollectionProcessingState?) {
    guard processingState?.operation?.state == .running else { return }
    if let folders = processingState?.folders {
      processingState?.folders = folders.map { record in
        guard record.state == .pending else { return record }
        var uncertain = record
        uncertain.state = .uncertain
        uncertain.reason = .interrupted

        return uncertain
      }
    }
    try? finishProcessingOperation(&processingState, state: Task.isCancelled ? .interrupted : .failed)
  }

  /// Rechecks installed evidence after a failed action while keeping its failed attempt separate.
  private func recoverManualProcessing(
    _ processingState: inout CollectionProcessingState?, root: URL, child: String, saved: FolderRecord?
  ) {
    guard processingState?.operation?.state == .running else { return }
    if let candidate = try? fileSystem.readCurrentState(ofChild: child, in: root),
      var record = try? assessFolderProcessing(candidate, root: root, saved: saved)
    {
      record.lastFailure = FolderProcessingFailure(
        reason: Task.isCancelled ? .cancelled : .unknown, stage: .unknown, occurredAt: now())
      if record.state != .done && record.state != .preserved && record.state != .suppressed {
        record.state = .uncertain
        record.reason = .interrupted
      }
      try? recordFolderProcessing(record, in: &processingState)
    }
    try? finishProcessingOperation(&processingState, state: Task.isCancelled ? .interrupted : .failed)
  }

  /// Ends one attempt without confusing action completion with a completed collection traversal.
  private func finishProcessingOperation(
    _ processingState: inout CollectionProcessingState?, state: CollectionProcessingOperationState
  ) throws {
    guard processingState != nil else { return }
    processingState?.operation?.state = state
    processingState?.operation?.endedAt = now()
    if state == .completed,
      processingState?.operation?.action == .automatic,
      processingState?.isInventoryComplete == true
    {
      let completed = processingState?.operation
      processingState?.lastCompletedRun = completed
    }
    try commitProcessingState(&processingState)
  }

  /// Updates one member and bounds whole-document checkpoint writes to batches of 32 assessments.
  private func recordFolderProcessing(
    _ record: FolderProcessingRecord,
    in processingState: inout CollectionProcessingState?
  ) throws {
    guard processingState != nil else { return }
    guard let index = processingState?.folders.firstIndex(where: { $0.name == record.name }) else {
      throw CollectionProcessingError.invalidState
    }
    processingState?.folders[index] = record
    let assessed = processingState?.folders.lazy.filter { $0.state != .pending }.count ?? .zero
    if assessed.isMultiple(of: 32) { try commitProcessingState(&processingState) }
  }

  /// Explains a root backoff for members that have not yet been assessed.
  private func deferPendingFolderAssessments(_ processingState: inout CollectionProcessingState?, until date: Date) {
    guard let current = processingState else { return }
    processingState?.folders = current.folders.map { record in
      guard record.state == .pending else { return record }
      var deferred = record
      deferred.state = .deferred
      deferred.reason = .retryDeferred
      deferred.retryAt = date
      deferred.assessedAt = now()

      return deferred
    }
  }

  /// Converts conservative matching evidence to its exclusive persisted state.
  private func unresolvedFolderAssessment(
    _ candidate: FolderCandidate, reason: FolderProcessingReason, movie: MovieMetadata? = nil
  ) -> FolderProcessingRecord {
    let state: FolderProcessingState
    switch reason {
    case .noSuitableMovie: state = .notFound
    case .ambiguousMovie: state = .severalMatches
    default: state = .unresolved
    }

    return FolderProcessingRecord(
      name: candidate.name, identity: candidate.identity, state: state, reason: reason,
      movieID: movie?.id, movieTitle: movie?.title, movieYear: movie?.releaseYear,
      movieIdentitySource: movie == nil ? nil : .conservativeMatch,
      ownership: .none, assessedAt: now(), retryAt: now().addingTimeInterval(Self.unresolvedRetryInterval),
      fingerprint: candidate.fingerprint)
  }

  /// Preserves the original unresolved reason while existing retry policy defers another provider request.
  private func cachedFolderAssessment(_ candidate: FolderCandidate, saved: FolderRecord) -> FolderProcessingRecord {
    var record = unresolvedFolderAssessment(candidate, reason: saved.processingReason ?? .retryDeferred)
    if saved.status == .transientFailure {
      record.state = .failed
      record.reason = saved.processingReason ?? .processingFailure
      record.lastFailure = saved.lastFailure
    } else if saved.processingReason == nil {
      record.state = .deferred
    }
    record.retryAt = saved.retryDate
    record.movieID = saved.matchedMovieID
    record.movieTitle = saved.movieTitle
    record.movieYear = saved.movieYear
    record.movieIdentitySource = saved.movieIdentitySource ?? (saved.matchedMovieID == nil ? nil : .savedDecision)

    return record
  }

  /// Records a failure without embedding provider messages or private paths.
  private func failedFolderAssessment(
    _ candidate: FolderCandidate, stage: FolderProcessingStage, movie: MovieMetadata? = nil
  ) -> FolderProcessingRecord {
    FolderProcessingRecord(
      name: candidate.name, identity: candidate.identity, state: .failed,
      reason: stage == .search ? .metadataFailure : (stage == .artwork ? .posterFailure : .filesystemFailure),
      movieID: movie?.id, movieTitle: movie?.title, movieYear: movie?.releaseYear,
      movieIdentitySource: movie == nil ? nil : .conservativeMatch,
      assessedAt: now(), retryAt: now().addingTimeInterval(Self.transientRetryInterval),
      lastFailure: FolderProcessingFailure(reason: .unavailable, stage: stage, occurredAt: now()),
      fingerprint: candidate.fingerprint)
  }

  /// Verifies current ownership instead of treating an assignment attempt or cached decision as success.
  private func assessFolderProcessing(
    _ candidate: FolderCandidate, root: URL, saved: FolderRecord?
  ) throws -> FolderProcessingRecord {
    let inspection = try fileSystem.inspectPoster(
      toChild: candidate.name, in: root, expectedIdentity: candidate.identity)
    var record = FolderProcessingRecord(
      name: candidate.name, identity: candidate.identity, state: .pending,
      assessedAt: now(), fingerprint: candidate.fingerprint)
    switch inspection.ownership {
    case .none: record.ownership = .none
    case .owned: record.ownership = .owned
    case .unowned: record.ownership = .unowned
    case .changed: record.ownership = .changed
    }
    if let saved, saved.fingerprint == candidate.fingerprint {
      record.movieID = saved.matchedMovieID
      record.movieTitle = saved.movieTitle
      record.movieYear = saved.movieYear
      record.movieIdentitySource = saved.movieIdentitySource ?? (saved.matchedMovieID == nil ? nil : .savedDecision)
    }
    if inspection.isSuppressed {
      record.state = .suppressed
      record.reason = .policySuppressed
    } else if record.ownership == .owned, (record.movieID ?? .zero) > .zero {
      record.state = .done
    } else if record.ownership == .unowned || record.ownership == .changed {
      record.state = .preserved
      record.reason = record.ownership == .changed ? .ownershipChanged : .existingPosterPreserved
    } else {
      record.state = .unresolved
      record.reason = .savedIdentityUnavailable
    }

    return record
  }

  /// Holds configuration validation through the final child check and automatic icon assignment.
  ///
  /// - Parameters:
  ///   - data: The encoded record or image bytes consumed by this operation.
  ///   - candidate: The child folder evidence captured before this operation.
  ///   - root: The authorized collection directory containing the immediate child.
  /// - Throws: Persistence, authorization, changed-folder, or icon-operation errors from the required processing step.
  private func assign(_ data: Data, to candidate: FolderCandidate, in root: URL) throws
    -> PosterAssignmentResult
  {
    try Task.checkCancellation()
    let settingsLease = try mutationGuard?.movieFolderProcessor(self, willPerformAutomaticMutationIn: root)
    defer { withExtendedLifetime(settingsLease) {} }
    let current: FolderCandidate
    do {
      current = try fileSystem.readCurrentState(ofChild: candidate.name, in: root)
    } catch {
      throw ProcessingFailure.changedIdentity
    }
    guard current.identity == candidate.identity else { throw ProcessingFailure.changedIdentity }

    return try posterAssigner.assignPoster(
      data, toChild: candidate.name, in: root,
      appearance: appearance, expectedIdentity: candidate.identity)
  }

  /// Restyles a cached owned poster when its finish differs and suppression permits mutation.
  ///
  /// - Parameters:
  ///   - candidate: The child folder evidence captured before this operation.
  ///   - root: The authorized collection directory containing the immediate child.
  ///   - state: The root processing state being inspected or updated.
  /// - Returns: Whether an owned poster was rewritten using the selected finish.
  /// - Throws: Persistence, authorization, changed-folder, or icon-operation errors from the required processing step.
  private func restyleOwnedPosterIfPossible(
    _ candidate: FolderCandidate, in root: URL, state: ProcessingState
  ) throws -> Bool {
    guard try !fileSystem.isPosterSuppressed(toChild: candidate.name, in: root),
      try fileSystem.hasAssignedPoster(
        toChild: candidate.name, in: root,
        expectedIdentity: candidate.identity)
    else { return false }
    guard
      try fileSystem.assignedPosterAppearance(
        toChild: candidate.name, in: root,
        expectedIdentity: candidate.identity) != appearance
    else {
      return false
    }
    guard let record = state.folders[candidate.name], record.fingerprint == candidate.fingerprint,
      record.status == .processed, let posterPath = record.posterPath,
      record.matchedMovieID != nil, let data = cachedPoster(for: posterPath)
    else { return false }
    try Task.checkCancellation()
    let current = try fileSystem.readCurrentState(ofChild: candidate.name, in: root)
    guard current.identity == candidate.identity else { throw ProcessingFailure.changedIdentity }
    let styleLease = try mutationGuard?.movieFolderProcessorWillPerformManualMutation(self)
    defer { withExtendedLifetime(styleLease) {} }
    let settingsLease = try mutationGuard?.movieFolderProcessor(self, willPerformAutomaticMutationIn: root)
    defer { withExtendedLifetime(settingsLease) {} }
    let result = try fileSystem.restyleAssignedPoster(
      data, toChild: candidate.name, in: root, appearance: appearance,
      expectedIdentity: candidate.identity
    )
    if case .assigned = result { return true }

    return false
  }

  /// Stores an unresolved outcome with the conservative retry delay.
  ///
  /// - Parameters:
  ///   - candidate: The child folder evidence captured before this operation.
  ///   - state: The root processing state being inspected or updated.
  private func recordUnresolved(
    _ candidate: FolderCandidate, in state: inout ProcessingState,
    reason: FolderProcessingReason = .parsingProblem, movie: MovieMetadata? = nil
  ) {
    state.folders[candidate.name] = FolderRecord(
      fingerprint: candidate.fingerprint,
      status: .unresolved,
      retryDate: now().addingTimeInterval(Self.unresolvedRetryInterval),
      matchedMovieID: movie?.id,
      posterPath: movie?.posterPath,
      processingReason: reason,
      movieTitle: movie?.title,
      movieYear: movie?.releaseYear,
      movieIdentitySource: movie == nil ? nil : .conservativeMatch
    )
  }

  /// Stores a recoverable failure with its shorter retry delay.
  ///
  /// - Parameters:
  ///   - candidate: The child folder evidence captured before this operation.
  ///   - state: The root processing state being inspected or updated.
  private func recordTransientFailure(
    _ candidate: FolderCandidate, in state: inout ProcessingState,
    stage: FolderProcessingStage = .unknown, movie: MovieMetadata? = nil
  ) {
    state.folders[candidate.name] = FolderRecord(
      fingerprint: candidate.fingerprint,
      status: .transientFailure,
      retryDate: now().addingTimeInterval(Self.transientRetryInterval),
      matchedMovieID: movie?.id,
      posterPath: movie?.posterPath,
      processingReason: stage == .search ? .metadataFailure : (stage == .artwork ? .posterFailure : .processingFailure),
      movieTitle: movie?.title,
      movieYear: movie?.releaseYear,
      lastFailure: FolderProcessingFailure(reason: .unavailable, stage: stage, occurredAt: now()),
      movieIdentitySource: movie == nil ? nil : .conservativeMatch
    )
  }

  /// Decodes root processing state or supplies empty state when no record exists.
  ///
  /// - Parameter lease: The already-held persistence lease used throughout this operation.
  /// - Returns: The decoded root state, or empty state when no record has been saved.
  /// - Throws: Persistence, authorization, changed-folder, or icon-operation errors from the required processing step.
  private func loadState(from lease: PersistenceLease) throws -> ProcessingState {
    guard let data = try lease.read() else { return ProcessingState() }

    return try JSONDecoder().decode(ProcessingState.self, from: data)
  }

  /// Keeps a verified icon outcome distinct from failure to persist its operational cache.
  private func saveAssignedState(
    _ state: ProcessingState, to lease: PersistenceLease, candidate: FolderCandidate,
    root: URL, processingState: inout CollectionProcessingState?
  ) throws {
    do {
      try saveState(state, to: lease)
    } catch {
      if processingState != nil {
        var record = try assessFolderProcessing(candidate, root: root, saved: state.folders[candidate.name])
        record.reason = .cachePersistenceFailure
        record.lastFailure = FolderProcessingFailure(reason: .storage, stage: .persist, occurredAt: now())
        try recordFolderProcessing(record, in: &processingState)
        try finishProcessingOperation(&processingState, state: .failed)
      }
      throw error
    }
    if processingState != nil {
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
  private func saveState(_ state: ProcessingState, to lease: PersistenceLease) throws {
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
  private func cachedPoster(for path: String) -> Data? {
    let name = Self.posterCacheName(path)
    guard let data = try? fileSystem.readData(named: name, in: cacheDirectory),
      Self.isValidPoster(data)
    else { return nil }

    return data
  }

  /// Selects a bounded provider-wide retry boundary for authentication or rate-limit errors.
  ///
  /// - Parameter error: The failure whose retry or test behavior is being selected.
  /// - Returns: The retry boundary when the error requires root backoff.
  private func rootBackoff(for error: TMDbError) -> Date? {
    switch error {
    case .authentication:
      return now().addingTimeInterval(Self.maximumRateLimitInterval)
    case .rateLimited(let retryAfter):
      let interval = Self.retryInterval(from: retryAfter, now: now())

      return now().addingTimeInterval(interval)
    default:
      return nil
    }
  }

  /// Parses seconds or an HTTP date and clamps the provider retry interval to supported bounds.
  ///
  /// - Parameters:
  ///   - retryAfter: The provider Retry-After value in seconds or HTTP-date form.
  ///   - now: The clock used for retry and cache expiry decisions.
  /// - Returns: The bounded delay in seconds.
  private static func retryInterval(from retryAfter: String?, now: Date) -> TimeInterval {
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
      requested = nil
    }

    return min(
      max(requested ?? Self.transientRetryInterval, Self.minimumRateLimitInterval),
      Self.maximumRateLimitInterval)
  }

  /// Hashes the normalized title/year pair into a filesystem-independent cache key.
  ///
  /// - Parameters:
  ///   - title: The movie title used for search or exact normalized comparison.
  ///   - year: The release year when available; no value preserves year uncertainty.
  /// - Returns: The SHA-256 cache key for this title and optional release year.
  private static func queryKey(title: String, year: Int?) -> String {
    digest("\(title.lowercased())|\(year.map(String.init) ?? "")")
  }

  /// Hashes the provider poster path into a bounded cache filename.
  ///
  /// - Parameter path: The provider-relative source poster path.
  /// - Returns: The poster cache filename derived from the provider path digest.
  private static func posterCacheName(_ path: String) -> String { "poster-\(digest(path))" }

  /// Encodes a UTF-8 input as a lowercase SHA-256 digest.
  ///
  /// - Parameter value: The query or provider poster path to encode as a stable digest.
  /// - Returns: The lowercase hexadecimal SHA-256 digest of the UTF-8 input.
  private static func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// Requires complete image data that ImageIO can decode into a thumbnail.
  ///
  /// - Parameter data: The encoded record or image bytes consumed by this operation.
  /// - Returns: Whether the bytes contain a complete image that ImageIO can decode into a thumbnail.
  private static func isValidPoster(_ data: Data) -> Bool {
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

/// Internal processing failures recorded or propagated by the automatic pipeline.
nonisolated private enum ProcessingFailure: Error {
  case changedIdentity
  case invalidPoster
}

/// The last persisted outcome used to decide whether and when a folder should be retried.
nonisolated private enum FolderRecordStatus: String, Codable {
  case processed
  case unresolved
  case transientFailure
}

/// Persisted movie decision associated with one folder fingerprint.
nonisolated private struct FolderRecord: Codable {
  /// The folder identity and name associated with a persisted decision.
  let fingerprint: String
  /// The persisted outcome determining reuse and retry behavior.
  let status: FolderRecordStatus
  /// The earliest automatic retry time for an unresolved or failed folder.
  let retryDate: Date?
  /// The explicit or confidently matched TMDb identity, when recorded.
  let matchedMovieID: Int?
  /// The provider-relative source poster path, when available.
  let posterPath: String?
  /// Detailed unresolved evidence; absent on older cache records.
  var processingReason: FolderProcessingReason? = nil
  /// Saved provider title, when available.
  var movieTitle: String? = nil
  /// Saved provider release year, when available.
  var movieYear: Int? = nil
  /// Safe latest failure evidence retained through retry deferral.
  var lastFailure: FolderProcessingFailure? = nil
  private enum CodingKeys: String, CodingKey {
    case fingerprint, status, retryDate, matchedMovieID, posterPath, processingReason, movieTitle, movieYear
    case lastFailure = "latestAttempt"
    case movieIdentitySource
  }
  /// How the saved movie identity was established.
  var movieIdentitySource: MovieIdentitySource? = nil
}

/// Per-root folder decisions, cached searches, and provider backoff persisted together.
nonisolated private struct ProcessingState: Codable {
  /// Processing decisions keyed by immediate child folder name.
  var folders: [String: FolderRecord] = [:]
  /// Cached provider responses keyed by normalized query digest.
  var queries: [String: CachedSearch] = [:]
  /// The provider-wide retry boundary saved for this root, when present.
  var rootBackoffUntil: Date?
}

/// Codable search results with their completeness evidence and creation time.
nonisolated private struct CachedSearch: Codable {
  /// Movie records retained from the cached response.
  let movies: [CachedMovie]
  /// Whether unexamined search pages prevent a unique automatic match.
  let hasMorePages: Bool
  /// When the search response entered the cache.
  let createdAt: Date

  /// Stores a provider response and creation time in a Codable representation.
  ///
  /// - Parameters:
  ///   - result: The provider response whose movie records and pagination evidence are cached.
  ///   - createdAt: The instant used to evaluate future cache expiry.
  init(result: MovieSearchResult, createdAt: Date) {
    movies = result.movies.map(CachedMovie.init)
    hasMorePages = result.hasMorePages
    self.createdAt = createdAt
  }

  /// Reconstructs the provider response from cached movie records and pagination evidence.
  /// - Returns: A new search response with each cached movie restored to provider metadata.
  func searchResult() -> MovieSearchResult {
    MovieSearchResult(movies: movies.map(\.metadata), hasMorePages: hasMorePages)
  }
}

/// Codable movie identity and source poster path stored with a cached search.
nonisolated private struct CachedMovie: Codable {
  /// Stable identity of the represented collection or movie record.
  let id: Int
  /// The display or parsed movie title used by the matching workflow.
  let title: String
  /// The original-language title considered alongside the localized title.
  let originalTitle: String
  /// The provider release year, or no value when unavailable.
  let releaseYear: Int?
  /// The provider-relative source poster path, when available.
  let posterPath: String?

  /// Copies the provider movie fields required to restore cached matching evidence.
  ///
  /// - Parameter movie: The explicit provider movie record to retain or apply.
  init(_ movie: MovieMetadata) {
    id = movie.id
    title = movie.title
    originalTitle = movie.originalTitle
    releaseYear = movie.releaseYear
    posterPath = movie.posterPath
  }

  /// The provider movie representation reconstructed from its cached fields.
  var metadata: MovieMetadata {
    MovieMetadata(
      id: id, title: title, originalTitle: originalTitle,
      releaseYear: releaseYear, posterPath: posterPath)
  }
}
