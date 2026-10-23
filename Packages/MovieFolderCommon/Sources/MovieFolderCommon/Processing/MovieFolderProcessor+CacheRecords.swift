import FileSystem
import Foundation
import Network
import Persistence

/// Internal processing failures recorded or propagated by the automatic pipeline.
nonisolated enum ProcessingFailure: Error {
  case changedIdentity
  case invalidPoster
  case cacheWriteFailed
}

/// The last persisted outcome used to decide whether and when a folder should be retried.
nonisolated enum FolderRecordStatus: String, Codable {
  case processed
  case unresolved
  case transientFailure
}

/// Persisted movie decision associated with one folder fingerprint.
nonisolated struct FolderRecord: Codable {
  /// The folder identity and name associated with a persisted decision.
  let fingerprint: String
  /// The persisted outcome determining reuse and retry behavior.
  let status: FolderRecordStatus
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
  var lastFailure: FolderProcessingFailure?
  /// Preserves the cache record field names used by existing saved state.
  private enum CodingKeys: String, CodingKey {
    case fingerprint, status, retryDate, matchedMovieID, posterPath, processingReason, movieTitle, movieYear
    case lastFailure = "latestAttempt"
    case movieIdentitySource
    case nameParserRevision
    case requiresAutomaticReassessment
  }
  /// How the saved movie identity was established.
  var movieIdentitySource: MovieIdentitySource?
  /// Parser revision that produced an unresolved decision, absent in older saved records.
  var nameParserRevision: Int? = .none
  /// Retains historical installed-poster evidence while preventing assignment from an obsolete automatic decision.
  var requiresAutomaticReassessment: Bool? = .none

  /// Whether historic unresolved evidence needs a fresh classification rather than a cooldown retry.
  var needsLegacyReassessment: Bool { status == .unresolved && processingReason == .none }

  /// Whether unchanged evidence requires explicit action or a changed folder before another automatic attempt.
  var blocksAutomaticRecovery: Bool {
    requiresManualResolution ||
      (status == .unresolved && (processingReason == .parsingProblem || processingReason == .missingArtwork
        || processingReason == .manualIdentificationRequired))
  }

  /// Whether this unchanged folder has a confirmed result that needs user resolution.
  var requiresManualResolution: Bool {
    status == .unresolved && (processingReason == .noSuitableMovie || processingReason == .ambiguousMovie)
  }
}

/// Per-root folder decisions, cached searches, and provider backoff persisted together.
nonisolated struct ProcessingState: Codable {
  /// Processing decisions keyed by immediate child folder name.
  var folders: [String: FolderRecord] = [:]
  /// Cached provider responses keyed by normalized query digest.
  var queries: [String: CachedSearch] = [:]
  /// The provider-wide retry boundary saved for this root, when present.
  var providerRetryAt: Date?
  /// Credential generation captured by the processor that last saved this operational state.
  var credentialRevision: UUID? = .none
  /// Effective choices used to produce automatic decisions; absent legacy records use established defaults.
  var identificationPolicy: IdentificationPolicy? = .none

  /// Invalidates automatic assignments while retaining installed-poster evidence and raw search responses.
  /// - Parameter policy: Current automatic identification choices.
  mutating func reconcileIdentificationPolicy(_ policy: IdentificationPolicy) {
    if (identificationPolicy ?? IdentificationPolicy()) != policy {
      folders = folders.compactMapValues { saved in
        if saved.movieIdentitySource == .explicitSelection { return saved }

        guard saved.matchedMovieID != .none, saved.posterPath != .none else { return .none }

        var retained = saved
        retained.requiresAutomaticReassessment = true

        return retained
      }
    }
    identificationPolicy = policy
  }

  /// Discards credential-sensitive evidence while retaining folder identities and explicit decisions.
  /// - Parameter revision: Captured production credential generation; absence preserves isolated legacy callers.
  mutating func reconcileCredentialRevision(_ revision: UUID?) {
    guard let revision, credentialRevision != revision else { return }

    queries.removeAll()

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
    case folders, queries, credentialRevision, identificationPolicy
    case providerRetryAt = "rootBackoffUntil"
  }
}

/// Codable search results with their completeness evidence and creation time.
nonisolated struct CachedSearch: Codable {
  /// Movie records retained from the cached response.
  private let movies: [CachedMovie]
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
