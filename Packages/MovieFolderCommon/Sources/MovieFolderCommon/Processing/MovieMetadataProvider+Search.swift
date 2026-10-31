import Foundation
import Network

nonisolated public extension MovieMetadataProvider {
  /// Collects pages sequentially within a captured global budget, publishing only a successful whole search.
  /// - Parameters:
  ///   - title: The provider query.
  ///   - year: Optional release year.
  ///   - language: Captured provider language.
  ///   - pageLimit: Captured maximum number of pages, from one through five.
  /// - Returns: First-seen unique movies and whether the finite budget left additional pages.
  /// - Throws: Invalid input, inconsistent provider records, any page failure, or cancellation.
  func searchMovies(title: String, year: Int?, language: TMDbLanguage, pageLimit: Int) async throws
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
        totalPages == .none || totalPages == result.totalPages else { throw TMDbError.malformedResponse }

      totalPages = result.totalPages
      for movie in result.movies {
        if let existing = identities[movie.id] {
          guard existing == movie else { throw TMDbError.malformedResponse }
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
