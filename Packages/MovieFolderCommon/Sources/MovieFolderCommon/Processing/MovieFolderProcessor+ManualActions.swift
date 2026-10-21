import FileSystem
import Foundation
import Network
import Persistence

extension MovieFolderProcessor {
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
    root: URL, child: String, expectedIdentity: String, processingContext: CollectionProcessingContext? = .none
  ) async throws -> Int {
    try Task.checkCancellation()
    try recovery?.validateProcessingAllowed()
    let coordinationLease = try acquireCoordinationLease(for: root)
    defer { withExtendedLifetime(coordinationLease) {} }
    let lease = try acquireRootLease(for: root)
    defer { withExtendedLifetime(lease) {} }
    var state = try loadState(from: lease)
    var processingState = try recordProcessingStart(context: processingContext, action: .refresh, child: child)
    defer { recoverManualProcessing(&processingState, root: root, child: child, saved: state.folders[child]) }
    var candidate = try actionCandidate(root: root, child: child, expectedIdentity: expectedIdentity)
    try ensureReplaceableIcon(for: candidate, in: root)

    let selection = try await refreshSelection(
      root: root, child: child, expectedIdentity: expectedIdentity, candidate: &candidate, state: &state)
    let movieID = selection.movieID
    let posterPath = selection.posterPath

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
    refreshedRecord.movieTitle = selection.movieTitle
    refreshedRecord.movieYear = selection.movieYear
    refreshedRecord.movieIdentitySource = state.folders[child]?.movieIdentitySource ?? .savedDecision
    state.folders[child] = refreshedRecord
    state.providerRetryAt = .none
    try saveAssignedState(state, to: lease, candidate: candidate, root: root, processingState: &processingState)
    try finishProcessingOperation(&processingState, state: .completed)

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
    processingContext: CollectionProcessingContext? = .none
  ) async throws -> Int {
    try Task.checkCancellation()
    try recovery?.validateProcessingAllowed()
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
    state.providerRetryAt = .none
    try saveAssignedState(state, to: lease, candidate: candidate, root: root, processingState: &processingState)
    try finishProcessingOperation(&processingState, state: .completed)

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
    root: URL, child: String, expectedIdentity: String, processingContext: CollectionProcessingContext? = .none
  ) throws -> Bool {
    try Task.checkCancellation()
    try recovery?.validateProcessingAllowed()
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

      if processingState != .none {
        let record = try assessFolderProcessing(candidate, root: root, saved: state.folders[child])
        try recordFolderProcessing(record, in: &processingState)
        try finishProcessingOperation(&processingState, state: .completed)
      }
      return false
    }
    try Task.checkCancellation()
    let removed: Bool
    do {
      let recoveryLease = try recovery?.acquireMutationLease()
      defer { withExtendedLifetime(recoveryLease) {} }
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
    try saveAssignedState(state, to: lease, candidate: candidate, root: root, processingState: &processingState)
    try finishProcessingOperation(&processingState, state: .completed)

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
    else { return .none }

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
  func acquireCoordinationLease(for root: URL) throws -> PersistenceLease? {
    guard let coordinationStore else { return .none }
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
  func actionCandidate(root: URL, child: String, expectedIdentity: String) throws -> FolderCandidate {
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
    let recoveryLease = try recovery?.acquireMutationLease()
    defer { withExtendedLifetime(recoveryLease) {} }
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
      fingerprint: candidate.fingerprint, status: .processed, retryDate: .none,
      matchedMovieID: movieID, posterPath: posterPath)
  }

  /// Derives the processing-state lease key from the canonical root path.
  ///
  /// - Parameter root: The authorized collection directory containing the immediate child.
  /// - Returns: The processing lease key namespaced by the canonical root path.
  static func rootLeaseKey(for root: URL) -> String {
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

  /// Resolves the saved refresh identity or searches and rechecks the manual target after suspension.
  private func refreshSelection(
    root: URL, child: String, expectedIdentity: String, candidate: inout FolderCandidate, state: inout ProcessingState
  ) async throws -> RefreshMovieSelection {
    let movieID: Int
    let posterPath: String
    var freshSearch: CachedSearch?
    var movieTitle = state.folders[child]?.movieTitle
    var movieYear = state.folders[child]?.movieYear
    if let record = state.folders[child], record.fingerprint == candidate.fingerprint,
      record.status == .processed, let savedMovieID = record.matchedMovieID,
      let savedPosterPath = record.posterPath {
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

    return RefreshMovieSelection(
      movieID: movieID, posterPath: posterPath, movieTitle: movieTitle, movieYear: movieYear)
  }
}

/// Movie evidence retained while fresh refresh artwork is downloaded.
private struct RefreshMovieSelection {
  /// The saved or conservatively matched provider identity.
  let movieID: Int
  /// The source artwork path selected for refresh.
  let posterPath: String
  /// Saved or freshly matched title evidence.
  let movieTitle: String?
  /// Saved or freshly matched release year evidence.
  let movieYear: Int?
}
