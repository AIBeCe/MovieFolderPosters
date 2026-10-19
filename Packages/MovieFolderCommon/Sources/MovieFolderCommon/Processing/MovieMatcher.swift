import Foundation
import Network

/// A reason search results cannot establish a unique movie with a poster.
nonisolated enum MovieMatchIssue: Equatable, Sendable {
  case invalidQuery
  case incompleteSearch
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
    let result = identify(title: title, year: year, search: search)
    guard case .matched(let selected) = result else { return result }
    guard let poster = selected.posterPath, !poster.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .unresolved(.missingPoster)
    }

    return result
  }

  /// Establishes identity independently of artwork availability using unchanged conservative evidence rules.
  func identify(title: String, year: Int?, search: MovieSearchResult) -> MovieMatchResult {
    let query = normalized(title)
    guard !query.isEmpty, year.map({ (1888...2099).contains($0) }) ?? true else {
      return .unresolved(.invalidQuery)
    }
    guard !search.hasMorePages else { return .unresolved(.incompleteSearch) }
    let plausible = search.movies.filter {
      (normalized($0.title) == query || normalized($0.originalTitle) == query)
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
