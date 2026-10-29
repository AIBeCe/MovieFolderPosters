import FileSystem
import Foundation
import MovieFolderParsing
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
    let activity = ProcessorActivityLog(context: activityLogContext, action: .posterRefresh, child: child)
    do {
      let result = try await performRefreshPoster(
        root: root, child: child, expectedIdentity: expectedIdentity,
        processingContext: processingContext, activity: activity)
      await flushActivityLog(activity)

      return result
    } catch {
      recordActivityFailure(error, in: activity)
      await flushActivityLog(activity)
      throw error
    }
  }

  /// Executes the operation while retaining its existing processing access and safety fences.
  private func performRefreshPoster(
    root: URL, child: String, expectedIdentity: String,
    processingContext: CollectionProcessingContext? = .none, activity: ProcessorActivityLog
  ) async throws -> Int {
    try Task.checkCancellation()
    try recovery?.validateProcessingAllowed()
    let coordinationAccess = try acquireCoordinationAccess(for: root)
    defer { withExtendedLifetime(coordinationAccess) {} }
    let access = try acquireRootAccess(for: root)
    defer { withExtendedLifetime(access) {} }
    var state = try loadState(from: access)
    var candidate = try actionCandidate(root: root, child: child, expectedIdentity: expectedIdentity)
    try ensureReplaceableIcon(for: candidate, in: root)

    do {
      let settingsAccess = try checkIconChange(.manualPosterAssignment, to: candidate, in: root)
      withExtendedLifetime(settingsAccess) {}
    }

    var processingState = try recordProcessingStart(context: processingContext, action: .refresh, child: child)
    defer { recoverManualProcessing(&processingState, root: root, child: child, saved: state.folders[child]) }
    let selection: RefreshMovieSelection
    do {
      selection = try await refreshSelection(
        root: root, child: child, expectedIdentity: expectedIdentity,
        candidate: &candidate, state: &state, activity: activity)
    } catch {
      if let saved = state.folders[child], saved.fingerprint == candidate.fingerprint,
        saved.processingReason == .manualMatchingRequired {
        try saveState(state, to: access, activity: activity)
        try recordFolderProcessing(cachedFolderAssessment(candidate, saved: saved),
          in: &processingState, activity: activity)
        try finishProcessingRun(&processingState, state: .failed, activity: activity)
      }
      throw error
    }
    let movieID = selection.movieID
    let posterPath = selection.posterPath
    activity.movie = MovieMetadata(id: movieID, title: selection.movieTitle ?? "",
      originalTitle: selection.movieTitle ?? "", releaseYear: selection.movieYear, posterPath: posterPath)
    activity.stage = .artwork
    let imageData = try await provider.downloadPoster(path: posterPath)
    try Task.checkCancellation()
    guard Self.isValidPoster(imageData) else { throw PosterActionError.noPoster }
    candidate = try actionCandidate(root: root, child: child, expectedIdentity: expectedIdentity)
    try ensureReplaceableIcon(for: candidate, in: root)
    activity.stage = .assignPoster
    do {
      let settingsAccess = try checkIconChange(.manualPosterAssignment, to: candidate, in: root)
      defer { withExtendedLifetime(settingsAccess) {} }
      try replacePoster(imageData, candidate: candidate, root: root)
    }
    activity.append(.posterApplied)
    try? fileSystem.writeData(imageData, named: Self.posterCacheName(posterPath), in: cacheDirectory)
    var refreshedRecord = processedRecord(for: candidate, movieID: movieID, posterPath: posterPath)
    refreshedRecord.movieTitle = selection.movieTitle
    refreshedRecord.movieYear = selection.movieYear
    refreshedRecord.movieIdentitySource = state.folders[child]?.movieIdentitySource ?? .savedDecision
    refreshedRecord.requiresAutomaticReassessment = state.folders[child]?.requiresAutomaticReassessment
    state.folders[child] = refreshedRecord
    state.providerRetryAt = .none
    try saveAssignedState(
      state, to: access, candidate: candidate, root: root, processingState: &processingState, activity: activity)
    try finishProcessingRun(&processingState, state: .completed, activity: activity)

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
    let activity = ProcessorActivityLog(context: activityLogContext, action: .posterSelection, child: child)
    do {
      let result = try await performApplyMoviePoster(
        movie, root: root, child: child, expectedIdentity: expectedIdentity,
        processingContext: processingContext, activity: activity)
      await flushActivityLog(activity)

      return result
    } catch {
      recordActivityFailure(error, in: activity)
      await flushActivityLog(activity)
      throw error
    }
  }

  /// Executes the operation while retaining its existing processing access and safety fences.
  private func performApplyMoviePoster(
    _ movie: MovieMetadata, root: URL, child: String, expectedIdentity: String,
    processingContext: CollectionProcessingContext? = .none, activity: ProcessorActivityLog
  ) async throws -> Int {
    try Task.checkCancellation()
    try recovery?.validateProcessingAllowed()
    let coordinationAccess = try acquireCoordinationAccess(for: root)
    defer { withExtendedLifetime(coordinationAccess) {} }
    let access = try acquireRootAccess(for: root)
    defer { withExtendedLifetime(access) {} }
    var state = try loadState(from: access)

    guard movie.id > 0 else { throw PosterActionError.unresolved }

    activity.movie = movie
    activity.stage = .artwork

    guard let posterPath = movie.posterPath,
      !posterPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw PosterActionError.noPoster
    }

    var candidate = try actionCandidate(root: root, child: child, expectedIdentity: expectedIdentity)
    try ensureReplaceableIcon(for: candidate, in: root)
    do {
      let settingsAccess = try checkIconChange(.manualPosterAssignment, to: candidate, in: root)
      withExtendedLifetime(settingsAccess) {}
    }

    var processingState = try recordProcessingStart(context: processingContext, action: .selection, child: child)
    defer { recoverManualProcessing(&processingState, root: root, child: child, saved: state.folders[child]) }
    activity.stage = .artwork
    let imageData = try await provider.downloadPoster(path: posterPath)
    try Task.checkCancellation()
    guard Self.isValidPoster(imageData) else { throw PosterActionError.noPoster }
    candidate = try actionCandidate(root: root, child: child, expectedIdentity: expectedIdentity)
    try ensureReplaceableIcon(for: candidate, in: root)
    activity.stage = .assignPoster
    do {
      let settingsAccess = try checkIconChange(.manualPosterAssignment, to: candidate, in: root)
      defer { withExtendedLifetime(settingsAccess) {} }
      try replacePoster(imageData, candidate: candidate, root: root)
    }
    activity.append(.posterApplied)
    try? fileSystem.writeData(imageData, named: Self.posterCacheName(posterPath), in: cacheDirectory)
    var selectedRecord = processedRecord(for: candidate, movieID: movie.id, posterPath: posterPath)
    selectedRecord.movieTitle = movie.title
    selectedRecord.movieYear = movie.releaseYear
    selectedRecord.movieIdentitySource = .explicitSelection
    state.folders[child] = selectedRecord
    state.providerRetryAt = .none
    try saveAssignedState(
      state, to: access, candidate: candidate, root: root, processingState: &processingState, activity: activity)
    try finishProcessingRun(&processingState, state: .completed, activity: activity)

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
  ) async throws -> Bool {
    let activity = ProcessorActivityLog(context: activityLogContext, action: .posterRemoval, child: child)
    do {
      let result = try performRemovePoster(
        root: root, child: child, expectedIdentity: expectedIdentity,
        processingContext: processingContext, activity: activity)
      await flushActivityLog(activity)

      return result
    } catch {
      recordActivityFailure(error, in: activity)
      await flushActivityLog(activity)
      throw error
    }
  }

  /// Executes the operation while retaining its existing processing access and safety fences.
  private func performRemovePoster(
    root: URL, child: String, expectedIdentity: String,
    processingContext: CollectionProcessingContext? = .none, activity: ProcessorActivityLog
  ) throws -> Bool {
    try Task.checkCancellation()
    try recovery?.validateProcessingAllowed()
    let coordinationAccess = try acquireCoordinationAccess(for: root)
    defer { withExtendedLifetime(coordinationAccess) {} }
    let access = try acquireRootAccess(for: root)
    defer { withExtendedLifetime(access) {} }
    var state = try loadState(from: access)
    var processingState = try recordProcessingStart(context: processingContext, action: .removal, child: child)
    defer { recoverManualProcessing(&processingState, root: root, child: child, saved: state.folders[child]) }
    let candidate = try actionCandidate(root: root, child: child, expectedIdentity: expectedIdentity)
    activity.movie = savedActivityMovie(state.folders[child], candidate: candidate)
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
        try recordFolderProcessing(record, in: &processingState, activity: activity)
        try finishProcessingRun(&processingState, state: .completed, activity: activity)
      }
      activity.append(.noPosterToRemove)

      return false
    }
    try Task.checkCancellation()
    activity.stage = .assignPoster
    let removed: Bool
    do {
      let recoveryAccess = try recovery?.acquireProcessingAccess()
      defer { withExtendedLifetime(recoveryAccess) {} }
      let settingsAccess = try checkIconChange(.posterRemoval, to: candidate, in: root)
      defer { withExtendedLifetime(settingsAccess) {} }
      removed = try fileSystem.removeAssignedPoster(
        toChild: child, in: root, expectedIdentity: expectedIdentity
      )
    } catch let error as FolderPosterError {
      if case .invalidChild = error { throw PosterActionError.changedIdentity }
      throw error
    }

    guard removed else {
      activity.append(.noPosterToRemove)

      return false
    }

    activity.append(.posterRemoved)
    state.folders.removeValue(forKey: child)
    try saveAssignedState(
      state, to: access, candidate: candidate, root: root, processingState: &processingState, activity: activity)
    try finishProcessingRun(&processingState, state: .completed, activity: activity)

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
    let coordinationAccess = try acquireCoordinationAccess(for: root)
    defer { withExtendedLifetime(coordinationAccess) {} }
    let access = try acquireRootAccess(for: root)
    defer { withExtendedLifetime(access) {} }
    let candidate = try actionCandidate(root: root, child: child, expectedIdentity: expectedIdentity)
    guard let record = try loadState(from: access).folders[child],
      record.fingerprint == candidate.fingerprint, record.status == .processed
    else { return .none }

    guard try mayReuseSavedIdentity(record, candidate: candidate, root: root) else { return .none }

    return record.matchedMovieID
  }

  /// Acquires the root processing access or reports contention.
  ///
  /// - Parameter root: The authorized collection directory containing the immediate child.
  /// - Returns: The held persistence access.
  /// - Throws: Persistence, authorization, changed-folder, or icon-operation errors from the required processing step.
  private func acquireRootAccess(for root: URL) throws -> PersistenceAccess {
    guard let access = try persistence.acquireAccess(for: Self.processingStateKey(for: root)) else {
      throw PosterActionError.busy
    }

    return access
  }

  /// Acquires the optional stable root lock shared by different settings generations.
  ///
  /// - Parameter root: The authorized collection directory containing the immediate child.
  /// - Returns: The held access when coordination is configured.
  /// - Throws: Persistence, authorization, changed-folder, or icon-operation errors from the required processing step.
  func acquireCoordinationAccess(for root: URL) throws -> PersistenceAccess? {
    guard let coordinationStore else { return .none }
    guard let access = try coordinationStore.acquireAccess(for: Self.rootCoordinationKey(for: root)) else {
      throw PosterActionError.busy
    }

    return access
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
    let recoveryAccess = try recovery?.acquireProcessingAccess()
    defer { withExtendedLifetime(recoveryAccess) {} }
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

  /// Derives the persisted processing-state key from the canonical root path.
  ///
  /// - Parameter root: The authorized collection directory containing the immediate child.
  /// - Returns: The processing-state key namespaced by the canonical root path.
  static func processingStateKey(for root: URL) -> String {
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
    root: URL, child: String, expectedIdentity: String, candidate: inout FolderCandidate, state: inout ProcessingState,
    activity: ProcessorActivityLog
  ) async throws -> RefreshMovieSelection {
    let movieID: Int
    let posterPath: String
    var freshSearch: CachedSearch?
    var movieTitle = state.folders[child]?.movieTitle
    var movieYear = state.folders[child]?.movieYear
    if let record = state.folders[child], record.fingerprint == candidate.fingerprint,
      record.status == .processed, let savedMovieID = record.matchedMovieID,
      let savedPosterPath = record.posterPath,
      try mayReuseSavedIdentity(record, candidate: candidate, root: root) {
      movieID = savedMovieID
      posterPath = savedPosterPath
    } else {
      guard case .parsed(let parsed) = parser.parse(child) else {
        activity.append(.unresolved, reason: .parsingProblem)
        throw PosterActionError.unresolved
      }

      if movieMatchingConfiguration.requiresReleaseYearForAutomaticMatching, parsed.year == .none {
        recordUnresolved(candidate, in: &state, reason: .manualMatchingRequired)
        activity.append(.unresolved, reason: .manualMatchingRequired)
        throw PosterActionError.unresolved
      }

      activity.stage = .search
      let key = try Self.queryKey(title: parsed.title, year: parsed.year,
        language: movieMatchingConfiguration.searchLanguage, credentialRevision: credentialRevision,
        usesFixtures: usesFixtureMetadata)
      let search = try await provider.searchMovies(title: parsed.title, year: parsed.year,
        language: movieMatchingConfiguration.searchLanguage)
      try Task.checkCancellation()
      candidate = try actionCandidate(root: root, child: child, expectedIdentity: expectedIdentity)
      try ensureReplaceableIcon(for: candidate, in: root)
      freshSearch = CachedSearch(result: search, createdAt: now())
      let match = try await assessMovie(title: parsed.title, year: parsed.year, search: search, state: &state)
      guard case .matched(let movie) = match else {
        let (reason, identifiedMovie) = unresolvedIdentity(match)
        activity.movie = identifiedMovie
        let result: MovieFolderActivityLogEvent.FolderResult = switch reason {
        case .noSuitableMovie: .notFound
        case .ambiguousMovie: .severalMatches
        default: .unresolved
        }
        if reason == .manualMatchingRequired { recordUnresolved(candidate, in: &state, reason: reason) }
        activity.append(result, reason: reason)
        throw PosterActionError.unresolved
      }
      if let saved = state.folders[child], saved.fingerprint == candidate.fingerprint,
        let confirmedID = saved.matchedMovieID, confirmedID != movie.id {
        recordUnresolved(candidate, in: &state, reason: .manualMatchingRequired)
        activity.movie = savedActivityMovie(state.folders[child], candidate: candidate)
        activity.append(.unresolved, reason: .manualMatchingRequired)
        throw PosterActionError.unresolved
      }

      guard let matchedPosterPath = movie.posterPath,
        !matchedPosterPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        activity.movie = movie
        activity.append(.unresolved, reason: .missingArtwork)
        throw PosterActionError.noPoster
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

  /// Keeps historical automatic identities usable only while their owned poster is still installed.
  /// - Parameters:
  ///   - record: Saved identity and artwork evidence.
  ///   - candidate: Current folder identity.
  ///   - root: Authorized collection root.
  /// - Returns: Whether explicit/current decisions or verified installed-poster evidence permit identity reuse.
  /// - Throws: Filesystem inspection or identity errors.
  private func mayReuseSavedIdentity(_ record: FolderRecord, candidate: FolderCandidate, root: URL) throws -> Bool {
    if record.requiresAutomaticReassessment != true { return true }

    return try fileSystem.hasAssignedPoster(toChild: candidate.name, in: root, expectedIdentity: candidate.identity)
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
