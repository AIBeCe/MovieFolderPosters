import Foundation

nonisolated public extension MovieMetadataProvider {
  /// Unsupported providers fail closed instead of falling back to weaker title matching.
  func movie(movieID: Int, language: MovieSearchLanguage) throws -> MovieMetadata? {
    throw MovieMetadataError.invalidConfiguration
  }

  /// Unsupported providers fail closed instead of manufacturing an empty successful lookup.
  func movie(imdbID: String, language: MovieSearchLanguage) throws -> MovieMetadata? {
    throw MovieMetadataError.invalidConfiguration
  }

  /// Collects pages sequentially within a captured global budget, publishing only a successful whole search.
  ///
  /// Identical records are deduplicated in provider order. Conflicting records or inconsistent page totals fail
  /// the entire search. Reaching the budget returns incomplete results; a page failure never returns partial success.
  ///
  /// ```swift
  /// let result = try await provider.searchMovies(title: "Dune", year: 2021, language: .english, pageLimit: 3)
  /// ```
  /// - Parameters:
  ///   - title: The provider query.
  ///   - year: Optional release year.
  ///   - language: Captured provider language.
  ///   - pageLimit: Captured maximum number of pages, from one through five.
  /// - Returns: First-seen unique movies and whether the finite budget left additional pages.
  /// - Throws: `ConfigurationError.invalidConfiguration` for an invalid budget, `MovieMetadataError.malformedResponse`
  ///   for inconsistent pages or conflicting records, `CancellationError`, or the provider's page error.
  func searchMovies(title: String, year: Int?, language: MovieSearchLanguage, pageLimit: Int) async throws
    -> MovieSearchResult {
    guard (1...5).contains(pageLimit) else { throw ConfigurationError.invalidConfiguration }

    var movies = [MovieMetadata]()
    var identities = [Int: MovieMetadata]()
    var totalPages: Int?
    var hasMorePages = false
    for requestedPage in 1...pageLimit {
      try Task.checkCancellation()
      let result = try await searchMoviePage(title: title, year: year, language: language, page: requestedPage)
      try Task.checkCancellation()

      guard result.page == requestedPage,
        result.totalPages >= requestedPage ||
          (requestedPage == 1 && result.totalPages == 0 && result.movies.isEmpty),
        totalPages == .none || totalPages == result.totalPages else { throw MovieMetadataError.malformedResponse }

      totalPages = result.totalPages
      for movie in result.movies {
        if let existing = identities[movie.id] {
          guard existing == movie else { throw MovieMetadataError.malformedResponse }
        } else {
          identities[movie.id] = movie
          movies.append(movie)
        }
      }
      hasMorePages = requestedPage < result.totalPages
      if !hasMorePages { break }
    }
    try Task.checkCancellation()

    return MovieSearchResult(movies: movies, hasMorePages: hasMorePages)
  }
}
