import Foundation
import Network

/// A reason search results cannot establish a unique movie with a poster.
nonisolated enum MovieMatchIssue: Equatable, Sendable {
  case invalidQuery
  case incompleteSearch
  case incompleteTitleEvidence
  case noSuitableMatch
  case ambiguous
  case missingPoster
}

/// Either a uniquely supported movie or an unresolved matching reason.
nonisolated enum MovieMatchResult: Equatable, Sendable {
  case matched(MovieMetadata)
  case unresolved(MovieMatchIssue)
}

/// Requires exact normalized title and available year agreement across complete search results.
nonisolated struct MovieMatcher: Sendable {
  /// Requires a unique movie identity supported by normalized title, year, and complete search evidence.
  ///
  /// - Parameters:
  ///   - title: The movie title used for search or exact normalized comparison.
  ///   - year: The release year when available; no value preserves year uncertainty.
  ///   - search: The provider response, including whether further search pages exist.
  /// - Returns: The unique match or explicit unresolved reason.
  func match(title: String, year: Int?, search: MovieSearchResult) -> MovieMatchResult {
    let result = matchMovie(title: title, year: year, search: search)
    guard case .matched(let selected) = result else { return result }
    guard let poster = selected.posterPath, !poster.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .unresolved(.missingPoster)
    }

    return result
  }

  /// Establishes identity independently of artwork availability using unchanged conservative evidence rules.
  /// - Parameters:
  ///   - title: Parsed title to compare using normalized exact matching.
  ///   - year: Parsed release year, or absence when unknown.
  ///   - search: Provider candidates and pagination-completeness evidence.
  ///   - configuration: Effective automatic choices controlling original-title comparison.
  /// - Returns: A uniquely supported identity or its unresolved classification.
  func matchMovie(title: String, year: Int?, search: MovieSearchResult,
                  configuration: MovieMatchingConfiguration = MovieMatchingConfiguration(),
                  alternativeTitles: MovieAlternativeTitles? = .none) -> MovieMatchResult {
    let query = normalized(title)
    guard !query.isEmpty, year.map({ (1888...2099).contains($0) }) ?? true else {
      return .unresolved(.invalidQuery)
    }
    guard !search.hasMorePages else { return .unresolved(.incompleteSearch) }
    if let issue = candidateIssue(title: title, year: year, search: search, configuration: configuration) {
      return .unresolved(issue)
    }
    let candidates = candidateIDs(year: year, search: search)
    if let alternativeTitles {
      guard Set(alternativeTitles.keys) == Set(candidates), alternativeTitles.values.joined().allSatisfy({
        !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }) else { return .unresolved(.incompleteTitleEvidence) }
    }
    let plausible = search.movies.filter {
      (normalized($0.title) == query || (configuration.comparesOriginalTitles && normalized($0.originalTitle) == query)
        || alternativeTitles?[$0.id]?.contains(where: { normalized($0.title) == query }) == true)
        && (year == .none || $0.releaseYear == year)
    }
    guard let selected = plausible.first else { return .unresolved(.noSuitableMatch) }
    guard plausible.allSatisfy({ $0.id == selected.id }),
      search.movies.filter({ $0.id == selected.id }).allSatisfy({ $0 == selected })
    else {
      return .unresolved(.ambiguous)
    }

    return .matched(selected)
  }

  /// Identifies all year-compatible movie IDs before spending any alternative-title requests.
  func candidateIDs(year: Int?, search: MovieSearchResult) -> [Int] {
    Array(Set(search.movies.filter { year == .none || $0.releaseYear == year }.map(\.id))).sorted()
  }

  /// Rejects invalid, incomplete, inconsistent, or oversized assessments before any alias request.
  func candidateIssue(title: String, year: Int?, search: MovieSearchResult,
                      configuration: MovieMatchingConfiguration = MovieMatchingConfiguration()) -> MovieMatchIssue? {
    guard !normalized(title).isEmpty, year.map({ (1888...2099).contains($0) }) ?? true else { return .invalidQuery }

    guard !search.hasMorePages else { return .incompleteSearch }

    guard search.movies.allSatisfy({ $0.id > 0 && !normalized($0.title).isEmpty
      && !normalized($0.originalTitle).isEmpty }) else { return .incompleteTitleEvidence }

    let identifiers = candidateIDs(year: year, search: search)

    guard identifiers.count <= 5 else { return .incompleteTitleEvidence }

    for id in identifiers {
      let records = search.movies.filter { $0.id == id }

      guard id > 0, let first = records.first, records.allSatisfy({ $0 == first }) else { return .ambiguous }
    }

    let query = normalized(title)
    let direct = search.movies.filter {
      (year == .none || $0.releaseYear == year) && (normalized($0.title) == query
        || (configuration.comparesOriginalTitles && normalized($0.originalTitle) == query))
    }

    guard Set(direct.map(\.id)).count <= 1 else { return .ambiguous }

    return .none
  }

  /// Folds case and accents, then normalizes punctuation and whitespace for exact title comparison.
  ///
  /// - Parameter title: The movie title used for search or exact normalized comparison.
  /// - Returns: The derived text or identity.
  private func normalized(_ title: String) -> String {
    let folded = title.folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: Locale(identifier: "en_US_POSIX"))

    return folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }.joined(separator: " ")
  }
}
