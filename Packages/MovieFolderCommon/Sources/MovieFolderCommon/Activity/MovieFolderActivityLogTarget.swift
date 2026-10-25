import Foundation

/// Historical display facts captured for one configured collection, never a search query or a full path.
nonisolated public struct MovieFolderActivityLogTarget: Codable, Sendable, Equatable {
  /// Collection display name observed when the event was produced.
  public let collectionName: String?
  /// Immediate child folder name, without parent path components.
  public let childFolderName: String?
  /// Confirmed provider movie identity, when available.
  public let movieID: Int?
  /// Title associated with a confirmed movie identity.
  public let movieTitle: String?
  /// Release year associated with a confirmed movie identity.
  public let movieYear: Int?

  /// Construction is restricted to root-bound context and committed removal evidence.
  init(collectionName: String?, childFolderName: String?, movieID: Int?, movieTitle: String?, movieYear: Int?) {
    self.collectionName = collectionName
    self.childFolderName = childFolderName
    self.movieID = movieID
    self.movieTitle = movieTitle
    self.movieYear = movieYear
  }
}

/// Immutable collection provenance and privacy captured before asynchronous work starts.
nonisolated public struct MovieFolderActivityLogContext: Sendable {
  /// Stable configured collection identity.
  public let collectionID: UUID
  /// Collection name captured from the authorized configuration model.
  public let collectionName: String
  /// Whether identifying history was prohibited when this context was captured.
  public let usesPrivateHistory: Bool

  /// Captures root-bound historical facts without retaining bookmarks or paths.
  /// - Parameter directory: The configured collection from which the operation begins.
  public init(directory: MonitoredDirectory) {
    collectionID = directory.id
    collectionName = directory.effectiveDisplayName
    usesPrivateHistory = directory.usesPrivateHistory
  }

  /// Captures the same facts from trusted configuration presentation state.
  /// - Parameter directoryStatus: The collection state rendered by the configuration interface.
  public init(directoryStatus: ConfiguredDirectoryStatus) {
    collectionID = directoryStatus.id
    collectionName = directoryStatus.effectiveDisplayName
    usesPrivateHistory = directoryStatus.usesPrivateHistory
  }

  /// Reconstitutes only repository-minted removal facts for the dedicated history entry point.
  init(removal: CommittedCollectionRemoval) {
    collectionID = removal.collectionID
    collectionName = removal.collectionName
    usesPrivateHistory = removal.usedPrivateHistory
  }

  /// Captures optional confirmed identity and immediate child context, unless private at capture time.
  /// - Parameters:
  ///   - childFolderName: Immediate child name, never an absolute or relative multi-component path.
  ///   - movieID: Confirmed provider identity, when available.
  ///   - movieTitle: Confirmed movie title, never a query or a guessed parsed title.
  ///   - movieYear: Confirmed release year.
  /// - Returns: Historical facts, or absence when capture-time privacy forbids them.
  public func target(
    childFolderName: String? = .none, movieID: Int? = .none,
    movieTitle: String? = .none, movieYear: Int? = .none
  ) -> MovieFolderActivityLogTarget? {
    guard !usesPrivateHistory else { return .none }

    let immediateChildName = childFolderName.flatMap {
      $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("/") ? .none : $0
    }

    return MovieFolderActivityLogTarget(collectionName: collectionName, childFolderName: immediateChildName,
      movieID: movieID, movieTitle: movieTitle, movieYear: movieYear)
  }

  /// Produces one root-bound event while preserving the privacy choice captured before the operation.
  /// - Parameters:
  ///   - action: Product operation whose evidence is being reported.
  ///   - status: Actual lifecycle result, independent of a parsed provider response.
  ///   - activityGroupID: Correlation for this operation; removed for capture-time private history.
  ///   - childFolderName: Immediate child name, never a full path.
  ///   - movieID: Confirmed provider movie identity.
  ///   - movieTitle: Title associated with the confirmed identity.
  ///   - movieYear: Year associated with the confirmed identity.
  ///   - folderResult: Actual folder terminal result, when this event concerns one folder.
  ///   - reason: Stable processing assessment supporting the result.
  ///   - failure: Allowlisted failure stage and category.
  ///   - retryAt: Earliest retry eligibility; never a promise of scheduled work.
  ///   - processingSummary: Actual counters for the completed collection visit.
  /// - Returns: Structured evidence with capture-time private identifiers and names removed.
  public func event(
    action: MovieFolderActivityLogEvent.Action, status: MovieFolderActivityLogEvent.Status,
    activityGroupID: UUID? = .none, childFolderName: String? = .none, movieID: Int? = .none,
    movieTitle: String? = .none, movieYear: Int? = .none,
    folderResult: MovieFolderActivityLogEvent.FolderResult? = .none, reason: FolderProcessingReason? = .none,
    failure: FolderProcessingFailure? = .none, retryAt: Date? = .none, processingSummary: ProcessingSummary? = .none
  ) -> MovieFolderActivityLogEvent {
    MovieFolderActivityLogEvent(action: action, status: status, activityGroupID: activityGroupID,
      collectionID: collectionID, target: target(childFolderName: childFolderName, movieID: movieID,
        movieTitle: movieTitle, movieYear: movieYear), folderResult: folderResult, reason: reason,
      failure: failure, retryAt: retryAt, processingSummary: processingSummary, activityLogContext: self)
  }
}
