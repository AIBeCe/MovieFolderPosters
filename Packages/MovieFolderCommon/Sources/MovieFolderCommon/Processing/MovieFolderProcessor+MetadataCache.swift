import CryptoKit
import Foundation
import Network

/// Persisted completed alias evidence; failed lookups never construct this record.
nonisolated struct CachedAlternativeTitles: Codable {
  /// Identity checked against the request before persistence and reuse.
  let movieID: Int
  /// Complete provider titles, including valid completed empty lists.
  let titles: [MovieAlternativeTitle]
  /// Time used for expiry and deterministic oldest-first eviction.
  let createdAt: Date
}

/// Structured request identity prevents delimiter collisions and cross-context metadata reuse.
nonisolated private struct MetadataCacheKey: Encodable {
  /// Endpoint category, distinct from decision semantics.
  let category: TMDbRequestCategory
  /// Encoded evidence format revision.
  let revision = 1
  /// Exact trimmed title; case and punctuation remain provider query evidence.
  let title: String?
  /// Optional supplied release year.
  let year: Int?
  /// Positive provider identity for alternative-title evidence.
  let movieID: Int?
  /// Effective language, retained even for language-independent alias endpoints.
  let language: TMDbLanguage
  /// Captured credential generation; absent only for isolated callers.
  let credentialRevision: UUID?
  /// Distinguishes explicit fixtures from production evidence.
  let usesFixtures: Bool

  /// Produces deterministic encoded evidence before hashing, avoiding concatenated-field ambiguities.
  func digest() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
  }
}

extension MovieFolderProcessor {
  /// Derives the query key using complete captured request context.
  static func queryKey(title: String, year: Int?, language: TMDbLanguage = .english,
                       credentialRevision: UUID? = .none, usesFixtures: Bool = false) throws -> String {
    try MetadataCacheKey(category: .movieSearch, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
      year: year, movieID: .none, language: language, credentialRevision: credentialRevision,
      usesFixtures: usesFixtures).digest()
  }

  /// Loads every eligible alias sequentially and applies the fixed five-ID ceiling before cache lookup.
  func assessMovie(title: String, year: Int?, search: MovieSearchResult,
                   state: inout ProcessingState) async throws -> MovieMatchResult {
    if let issue = matcher.candidateIssue(title: title, year: year, search: search,
      configuration: movieMatchingConfiguration) { return .unresolved(issue) }
    let identifiers = matcher.candidateIDs(year: year, search: search)
    var evidence = MovieAlternativeTitles()
    for id in identifiers {
      try Task.checkCancellation()
      let key = try MetadataCacheKey(category: .alternativeTitles, title: .none, year: .none, movieID: id,
        language: movieMatchingConfiguration.searchLanguage, credentialRevision: credentialRevision,
        usesFixtures: usesFixtureMetadata).digest()
      if let cached = state.alternativeTitles[key], cached.movieID == id,
        now().timeIntervalSince(cached.createdAt) >= 0,
        now().timeIntervalSince(cached.createdAt) < configuration.queryCacheLifetime {
        evidence[id] = cached.titles
        continue
      }
      let result = try await provider.alternativeTitles(movieID: id)
      try Task.checkCancellation()

      guard result.count == 1, let titles = result[id], titles.allSatisfy({
        !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }) else { return .unresolved(.incompleteTitleEvidence) }

      evidence[id] = titles
      let cached = CachedAlternativeTitles(movieID: id, titles: titles, createdAt: now())
      if try JSONEncoder().encode([key: cached]).count <= 512 * 1_024 {
        state.alternativeTitles[key] = cached
        try state.boundAlternativeTitleCache()
      }
    }

    return matcher.matchMovie(title: title, year: year, search: search,
      configuration: movieMatchingConfiguration, alternativeTitles: evidence)
  }
}

extension ProcessingState {
  /// Bounds only alias evidence, evicting oldest records and then lexical keys for timestamp ties.
  mutating func boundAlternativeTitleCache() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let oldest = alternativeTitles.keys.sorted {
      let first = alternativeTitles[$0]?.createdAt ?? .distantPast
      let second = alternativeTitles[$1]?.createdAt ?? .distantPast

      return first == second ? $0 < $1 : first < second
    }
    var index = Int.zero
    while try alternativeTitles.count > 128 || encoder.encode(alternativeTitles).count > 512 * 1_024 {
      alternativeTitles.removeValue(forKey: oldest[index])
      index += 1
    }
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
