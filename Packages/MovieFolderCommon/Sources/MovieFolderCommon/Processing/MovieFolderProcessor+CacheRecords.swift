import FileSystem
import Foundation
import Network
import Persistence

/// Internal processing failures recorded or propagated by the automatic pipeline.
nonisolated enum AutomaticProcessingIssue: Error {
  case changedIdentity
  case invalidPoster
  case cacheWriteFailed
}

/// The last persisted outcome used to decide whether and when a folder should be retried.
nonisolated enum FolderProcessingRecordStatus: String, Codable {
  case processed
  case unresolved
  case transientFailure
}

/// Persisted movie decision associated with one folder fingerprint.
nonisolated struct FolderProcessingCacheRecord: Codable {
  /// The folder identity and name associated with a persisted decision.
  let fingerprint: String
  /// The persisted outcome determining reuse and retry behavior.
  let status: FolderProcessingRecordStatus
  /// The earliest automatic retry time for an unresolved or failed folder.
  var retryDate: Date?
  /// The explicit or confidently matched TMDb identity, when recorded.
  let matchedMovieID: Int?
  /// The provider-relative source poster path, when available.
  let posterPath: String?
  /// Detailed unresolved evidence; absent on older cache records.
  var processingReason: FolderProcessingReason?
  /// Saved provider title, when available.
  var movieTitle: String?
  /// Saved provider release year, when available.
  var movieYear: Int?
  /// Safe latest failure evidence retained through retry deferral.
  var lastFailure: AutomaticFolderProcessingFailure?
  /// Preserves the cache record field names used by existing saved state.
  private enum CodingKeys: String, CodingKey {
    case fingerprint, status, retryDate, matchedMovieID, posterPath, processingReason, movieTitle, movieYear
    case lastFailure = "latestAttempt"
    case movieIdentitySource
    case nameParserRevision
    case requiresAutomaticReview = "requiresAutomaticReassessment"
    case acceptedMovieReleaseDates, savedMatchingRulesVersion
  }
  /// How the saved movie identity was established.
  var movieIdentitySource: MovieIdentitySource?
  /// Parser revision that produced an unresolved decision, absent in older saved records.
  var nameParserRevision: Int? = .none
  /// Retains historical installed-poster evidence while preventing assignment from an obsolete automatic decision.
  var requiresAutomaticReview: Bool? = .none

  /// Raw dated events supporting an automatic identity, absent in older records and explicit selections.
  var acceptedMovieReleaseDates: [MovieReleaseDate]? = .none
  /// Matching revision that completed a matching run; absent older unresolved decisions can be reviewed once.
  var savedMatchingRulesVersion: Int? = .none

  /// Derives all source-classified years without duplicating writable year evidence.
  func sourceClassifiedMovieYears() -> [MovieYear] {
    let primary = movieYear.map { [MovieYear(year: $0, type: .primaryRelease)] } ?? []

    return primary + (acceptedMovieReleaseDates ?? []).compactMap(\.movieYear)
  }

  /// Whether older unresolved evidence needs fresh matching rather than a cooldown retry.
  var isLegacyUnresolvedResult: Bool { status == .unresolved && processingReason == .none }

  /// Whether unchanged evidence requires explicit action or a changed folder before another automatic attempt.
  var blocksAutomaticRecovery: Bool {
    requiresManualResolution ||
      (status == .unresolved && (processingReason == .parsingProblem || processingReason == .missingArtwork
        || processingReason == .manualMatchingRequired))
  }

  /// Whether this unchanged folder has a confirmed result that needs user resolution.
  var requiresManualResolution: Bool {
    status == .unresolved && (processingReason == .noSuitableMovie || processingReason == .ambiguousMovie)
  }
}

/// Per-root folder decisions, cached searches, and provider backoff persisted together.
nonisolated struct CollectionProcessingCache: Codable {
  /// Current operational format; absent versions require explicit migration.
  var schemaVersion = 1
  /// Provider-verified title responses, independent of folder decisions.
  var alternativeTitles: [String: CachedMovieAlternativeTitles] = [:]
  /// Processing decisions keyed by immediate child folder name.
  var folders: [String: FolderProcessingCacheRecord] = [:]
  /// Cached provider responses keyed by normalized query digest.
  var queries: [String: CachedMovieSearch] = [:]
  /// The provider-wide retry boundary saved for this root, when present.
  var providerRetryAt: Date?
  /// Credential generation captured by the processor that last saved this operational state.
  var credentialRevision: UUID? = .none
  /// Effective choices used to produce automatic decisions; absent legacy records use established defaults.
  var movieMatchingConfiguration: MovieMatchingConfiguration? = MovieMatchingConfiguration()

  /// Creates a current empty state for a previously unseen root.
  init(folders: [String: FolderProcessingCacheRecord] = [:], queries: [String: CachedMovieSearch] = [:],
       providerRetryAt: Date? = .none, credentialRevision: UUID? = .none,
       movieMatchingConfiguration: MovieMatchingConfiguration? = MovieMatchingConfiguration()) {
    self.folders = folders
    self.queries = queries
    self.providerRetryAt = providerRetryAt
    self.credentialRevision = credentialRevision
    self.movieMatchingConfiguration = movieMatchingConfiguration
  }

  /// Requires an explicitly migrated current record before exposing any operational decisions.
  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)

    guard schemaVersion == 1 else {
      throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: values,
        debugDescription: "Operational state requires explicit storage migration")
    }

    folders = try values.decode([String: FolderProcessingCacheRecord].self, forKey: .folders)
    queries = try values.decode([String: CachedMovieSearch].self, forKey: .queries)
    alternativeTitles = try values.decode([String: CachedMovieAlternativeTitles].self, forKey: .alternativeTitles)
    providerRetryAt = try values.decodeIfPresent(Date.self, forKey: .providerRetryAt)
    credentialRevision = try values.decodeIfPresent(UUID.self, forKey: .credentialRevision)
    movieMatchingConfiguration = try values.decode(MovieMatchingConfiguration.self, forKey: .movieMatchingConfiguration)
  }

  /// Invalidates automatic assignments while retaining installed-poster evidence and raw search responses.
  /// - Parameter configuration: Current automatic matching choices.
  mutating func updateMatchingConfiguration(_ configuration: MovieMatchingConfiguration) {
    let previous = movieMatchingConfiguration ?? MovieMatchingConfiguration()
    let languageOnly = previous.requiresReleaseYearForAutomaticMatching
      == configuration.requiresReleaseYearForAutomaticMatching
      && previous.comparesOriginalTitles == configuration.comparesOriginalTitles
    if previous != configuration {
      folders = folders.compactMapValues { saved in
        if saved.movieIdentitySource == .explicitSelection { return saved }

        guard saved.matchedMovieID != .none else { return .none }

        var retained = saved
        if !languageOnly { retained.requiresAutomaticReview = true }

        return retained
      }
    }
    movieMatchingConfiguration = configuration
  }

  /// Discards credential-sensitive evidence while retaining folder identities and explicit decisions.
  /// - Parameter revision: Captured production credential generation; absence preserves isolated legacy callers.
  mutating func reconcileCredentialRevision(_ revision: UUID?) {
    guard let revision, credentialRevision != revision else { return }

    queries.removeAll()
    alternativeTitles.removeAll()

    for name in Array(folders.keys) {
      guard var record = folders[name] else { continue }

      if record.processingReason == .authentication {
        record.processingReason = .none
        record.retryDate = .none
      }
      if record.lastFailure?.reason == .authentication {
        record.lastFailure = .none
        record.retryDate = .none
      }

      folders[name] = record
    }
  }

  /// Preserves the existing cache field name when reading or writing saved processing state.
  private enum CodingKeys: String, CodingKey {
    case schemaVersion, folders, queries, credentialRevision, movieMatchingConfiguration, alternativeTitles
    case providerRetryAt = "rootBackoffUntil"
  }
}
