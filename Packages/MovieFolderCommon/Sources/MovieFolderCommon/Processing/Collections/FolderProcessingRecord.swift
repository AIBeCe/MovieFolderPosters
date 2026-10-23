import Foundation

/// Exclusive current assessment for an immediate child directory.
nonisolated public enum FolderProcessingState: String, Codable, Sendable, CaseIterable {
  case pending, done, notFound, severalMatches, unresolved, preserved, suppressed, failed, deferred, uncertain
}
/// Safe, stable explanations for a folder's current assessment.
nonisolated public enum FolderProcessingReason: String, Codable, Sendable, CaseIterable {
  case noSuitableMovie, ambiguousMovie, incompleteSearch, missingArtwork, parsingProblem
  case existingPosterPreserved, policySuppressed, processingFailure, retryDeferred
  case interrupted, inventoryPending, storageUnavailable, inspectionFailure, metadataFailure
  case posterFailure, filesystemFailure, savedIdentityUnavailable, ownershipChanged
  case capacityExceeded, cachePersistenceFailure, authentication, rateLimited, unknown
  case connectivity, serverFailure, invalidResponse, recoveryMode
  case manualIdentificationRequired
}
/// Ownership evidence for the icon currently installed on a folder.
nonisolated public enum PosterOwnership: String, Codable, Sendable {
  case unknown, none, owned, unowned, changed
}
/// Evidence source used to associate a folder with a provider movie identity.
nonisolated public enum MovieIdentitySource: String, Codable, Sendable {
  case conservativeMatch, explicitSelection, savedDecision
}
/// The authoritative current assessment and supporting evidence for one visible child directory.
nonisolated public struct FolderProcessingRecord: Codable, Sendable, Equatable, Identifiable {
  /// Stable record identifier derived from the child directory name.
  public var id: String { name }
  /// Directory name within the configured root.
  public let name: String
  /// Filesystem identity used to detect replacement.
  public var identity: String?
  /// Current mutually exclusive processing assessment.
  public var state: FolderProcessingState
  /// Optional stable explanation for the processing assessment.
  public var reason: FolderProcessingReason?
  /// Verified provider movie identifier, when available.
  public var movieID: Int?
  /// Display title associated with the verified movie identifier.
  public var movieTitle: String?
  /// Release year associated with the verified movie identifier.
  public var movieYear: Int?
  /// Source establishing the saved movie identity, when known.
  public var movieIdentitySource: MovieIdentitySource?
  /// Ownership evidence for the current installed icon.
  public var ownership: PosterOwnership
  /// Time the folder assessment was recorded.
  public var assessedAt: Date?
  /// Earliest time an automatic retry is eligible.
  public var retryAt: Date?
  /// Most recent failure evidence.
  public var lastFailure: FolderProcessingFailure?
  /// Optional stable change fingerprint for deduplicating work.
  public var fingerprint: String?

  /// Preserves the persisted field names independently of Swift property naming.
  private enum CodingKeys: String, CodingKey {
    case name, identity, state, reason, movieID, movieTitle, movieYear, movieIdentitySource
    case ownership, assessedAt, retryAt
    case lastFailure = "latestAttempt"
    case fingerprint
  }

  /// Creates a current folder assessment and its supporting evidence.
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
  ///   - assessedAt: Time the current assessment was recorded.
  ///   - retryAt: Earliest time an automatic retry is eligible.
  ///   - lastFailure: Safe category and stage from the most recent failure.
  ///   - fingerprint: Stable child-change fingerprint, when available.
  public init(name: String, identity: String? = .none, state: FolderProcessingState = .pending,
              reason: FolderProcessingReason? = .none, movieID: Int? = .none, movieTitle: String? = .none,
              movieYear: Int? = .none, movieIdentitySource: MovieIdentitySource? = .none,
              ownership: PosterOwnership = .unknown, assessedAt: Date? = .none,
              retryAt: Date? = .none, lastFailure: FolderProcessingFailure? = .none,
              fingerprint: String? = .none) {
    self.name = name
    self.identity = identity
    self.state = state
    self.reason = reason
    self.movieID = movieID
    self.movieTitle = movieTitle
    self.movieYear = movieYear
    self.movieIdentitySource = movieIdentitySource
    self.ownership = ownership
    self.assessedAt = assessedAt
    self.retryAt = retryAt
    self.lastFailure = lastFailure
    self.fingerprint = fingerprint
  }

  /// Whether the record contains the complete evidence required to count as Done.
  public var isVerifiedDone: Bool {
    state == .done && ownership == .owned && (movieID ?? .zero) > .zero &&
      identity?.isEmpty == false && assessedAt != .none
  }

  /// Retry deadline for an automatically recoverable outcome, excluding conclusive and admission-blocked reasons.
  var automaticRetryAt: Date? {
    guard state != .done, state != .notFound, state != .severalMatches,
      state != .preserved, state != .suppressed,
      let reason, let retryAt else { return .none }
    switch reason {
    case .noSuitableMovie, .ambiguousMovie, .parsingProblem, .missingArtwork,
         .authentication, .recoveryMode, .unknown, .manualIdentificationRequired:
      return .none
    default:
      return retryAt
    }
  }
}
