import Foundation

/// Exclusive current result for an immediate child directory.
nonisolated public enum FolderProcessingState: String, Codable, Sendable, CaseIterable {
  case pending, done, notFound, severalMatches, unresolved, preserved, suppressed, excluded, failed, deferred, uncertain
}
/// Safe, stable explanations for a folder's current result.
nonisolated public enum FolderProcessingReason: String, Codable, Sendable, CaseIterable {
  case noSuitableMovie, ambiguousMovie, incompleteSearch, missingArtwork, parsingProblem
  case existingPosterPreserved, policySuppressed, processingFailure, retryDeferred
  case interrupted, inventoryPending, storageUnavailable, inspectionFailure, metadataFailure
  case posterFailure, filesystemFailure, savedIdentityUnavailable, ownershipChanged
  case capacityExceeded, cachePersistenceFailure, authentication, rateLimited, unknown
  case connectivity, serverFailure, invalidResponse, recoveryMode
  case manualMatchingRequired, explicitExclusion
}
/// Ownership evidence for the icon currently installed on a folder.
nonisolated public enum FolderPosterOwnershipRecord: String, Codable, Sendable {
  case unknown, none, owned, unowned, changed
}
/// Evidence source used to associate a folder with a provider movie identity.
nonisolated public enum MovieIdentitySource: String, Codable, Sendable {
  case conservativeMatch, explicitSelection, savedDecision
}
/// The authoritative current result and supporting evidence for one visible child directory.
nonisolated public struct FolderProcessingRecord: Codable, Sendable, Equatable, Identifiable {
  /// Stable record identifier derived from the child directory name.
  public var id: String { folderName }
  /// Directory folderName within the configured root.
  public let folderName: String
  /// Filesystem identity used to detect replacement.
  public var folderIdentity: String?
  /// Current mutually exclusive processing result.
  public var processingState: FolderProcessingState
  /// Optional stable explanation for the processing result.
  public var processingReason: FolderProcessingReason?
  /// Verified provider movie identifier, when available.
  public var matchedMovieID: Int?
  /// Display title associated with the verified movie identifier.
  public var matchedMovieTitle: String?
  /// Release year associated with the verified movie identifier.
  public var matchedMovieYear: Int?
  /// Source establishing the saved movie identity, when known.
  public var movieIdentitySource: MovieIdentitySource?
  /// Ownership evidence for the current installed icon.
  public var ownership: FolderPosterOwnershipRecord
  /// Time the folder result was recorded.
  public var assessedAt: Date?
  /// Earliest time an automatic retry is eligible.
  public var nextRetryAt: Date?
  /// Most recent failure evidence.
  public var lastFailure: AutomaticFolderProcessingFailure?
  /// Optional stable change fingerprint for deduplicating work.
  public var folderFingerprint: String?

  /// Preserves the persisted field names independently of Swift property naming.
  private enum CodingKeys: String, CodingKey {
    case folderName = "name", folderIdentity = "identity", processingState = "state"
    case processingReason = "reason", matchedMovieID = "movieID", matchedMovieTitle = "movieTitle"
    case matchedMovieYear = "movieYear", movieIdentitySource, ownership, assessedAt
    case nextRetryAt = "retryAt", lastFailure = "latestAttempt", folderFingerprint = "fingerprint"
  }

  /// Creates a current folder result and its supporting evidence.
  ///
  /// - Parameters:
  ///   - name: Immediate child directory name.
  ///   - identity: Filesystem identity captured during inspection.
  ///   - state: Current exclusive processing outcome.
  ///   - reason: Safe explanation for the outcome.
  ///   - movieID: Verified positive provider movie identifier.
  ///   - movieTitle: Display title for that movie identifier.
  ///   - movieYear: Release year for that movie identifier.
  ///   - movieIdentitySource: Evidence source establishing the saved movie identity.
  ///   - ownership: Evidence for the currently installed icon.
  ///   - assessedAt: Time the current result was recorded.
  ///   - retryAt: Earliest time an automatic retry is eligible.
  ///   - lastFailure: Safe category and stage from the most recent failure.
  ///   - fingerprint: Stable child-change fingerprint, when available.
  public init(name: String, identity: String? = .none, state: FolderProcessingState = .pending,
              reason: FolderProcessingReason? = .none, movieID: Int? = .none, movieTitle: String? = .none,
              movieYear: Int? = .none, movieIdentitySource: MovieIdentitySource? = .none,
              ownership: FolderPosterOwnershipRecord = .unknown, assessedAt: Date? = .none,
              retryAt: Date? = .none, lastFailure: AutomaticFolderProcessingFailure? = .none,
              fingerprint: String? = .none) {
    folderName = name
    folderIdentity = identity
    processingState = state
    processingReason = reason
    matchedMovieID = movieID
    matchedMovieTitle = movieTitle
    matchedMovieYear = movieYear
    self.movieIdentitySource = movieIdentitySource
    self.ownership = ownership
    self.assessedAt = assessedAt
    nextRetryAt = retryAt
    self.lastFailure = lastFailure
    folderFingerprint = fingerprint
  }

  /// Whether the record contains the complete evidence required to count as Done.
  public var isVerifiedDone: Bool {
    processingState == .done && ownership == .owned && (matchedMovieID ?? .zero) > .zero &&
      folderIdentity?.isEmpty == false && assessedAt != .none
  }

  /// Retry deadline for an automatically recoverable outcome, excluding conclusive and admission-blocked reasons.
  var automaticRetryAt: Date? {
    guard processingState != .done, processingState != .notFound, processingState != .severalMatches,
      processingState != .preserved, processingState != .suppressed, processingState != .excluded,
      let processingReason, let nextRetryAt else { return .none }
    switch processingReason {
    case .noSuitableMovie, .ambiguousMovie, .parsingProblem, .missingArtwork,
         .authentication, .recoveryMode, .unknown, .manualMatchingRequired:
      return .none
    default:
      return nextRetryAt
    }
  }
}
