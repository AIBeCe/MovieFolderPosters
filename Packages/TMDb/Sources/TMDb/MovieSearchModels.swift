/// Movie fields returned from a TMDb search result.
struct MovieMetadata: Equatable, Sendable {
  /// The TMDb movie identifier.
  let id: Int
  /// The localized movie title.
  let title: String
  /// The movie's original-language title.
  let originalTitle: String
  /// The release year, when the release date is available and valid.
  let releaseYear: Int?
  /// The relative TMDb poster path, when the movie has a poster.
  let posterPath: String?

  /// Creates movie metadata using values decoded from a search result.
  ///
  /// - Parameters:
  ///   - id: The TMDb identifier.
  ///   - title: The localized title.
  ///   - originalTitle: The original-language title.
  ///   - releaseYear: The release year, if known.
  ///   - posterPath: The relative poster path, if available.
  init(id: Int, title: String, originalTitle: String, releaseYear: Int?, posterPath: String?) {
    self.id = id
    self.title = title
    self.originalTitle = originalTitle
    self.releaseYear = releaseYear
    self.posterPath = posterPath
  }
}

/// One validated provider page, before whole-search completeness is established.
struct MovieSearchPage: Equatable, Sendable {
  /// Movie records in provider order.
  let movies: [MovieMetadata]
  /// Positive requested and returned page number.
  let page: Int
  /// Provider page count; zero is valid only for an empty first page.
  let totalPages: Int

  /// Captures one provider page. The client and aggregator validate pagination before use.
  /// - Parameters:
  ///   - movies: The page's movie records.
  ///   - page: The returned page number.
  ///   - totalPages: The provider's total page count.
  init(movies: [MovieMetadata], page: Int, totalPages: Int) {
    self.movies = movies
    self.page = page
    self.totalPages = totalPages
  }
}
