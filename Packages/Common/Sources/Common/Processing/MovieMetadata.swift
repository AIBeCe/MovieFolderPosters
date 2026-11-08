/// Movie fields returned from a TMDb search result.
public struct MovieMetadata: Equatable, Sendable {
  /// The TMDb movie identifier.
  public let id: Int
  /// The localized movie title.
  public let title: String
  /// The movie's original-language title.
  public let originalTitle: String
  /// The release year, when the release date is available and valid.
  public let releaseYear: Int?
  /// The relative TMDb poster path, when the movie has a poster.
  public let posterPath: String?

  /// Creates movie metadata using values decoded from a search result.
  ///
  /// - Parameters:
  ///   - id: The TMDb identifier.
  ///   - title: The localized title.
  ///   - originalTitle: The original-language title.
  ///   - releaseYear: The release year, if known.
  ///   - posterPath: The relative poster path, if available.
  public init(id: Int, title: String, originalTitle: String, releaseYear: Int?, posterPath: String?) {
    self.id = id
    self.title = title
    self.originalTitle = originalTitle
    self.releaseYear = releaseYear
    self.posterPath = posterPath
  }
}

/// One validated provider page, before whole-search completeness is established.
public struct MovieSearchPage: Equatable, Sendable {
  /// Movie records in provider order.
  public let movies: [MovieMetadata]
  /// Positive requested and returned page number.
  public let page: Int
  /// Provider page count; zero is valid only for an empty first page.
  public let totalPages: Int

  /// Captures one provider page. The client and aggregator validate pagination before use.
  /// - Parameters:
  ///   - movies: The page's movie records.
  ///   - page: The returned page number.
  ///   - totalPages: The provider's total page count.
  public init(movies: [MovieMetadata], page: Int, totalPages: Int) {
    self.movies = movies
    self.page = page
    self.totalPages = totalPages
  }
}

/// Movies collected within a finite search budget.
public struct MovieSearchResult: Equatable, Sendable {
  /// The validated movie results in server order.
  public let movies: [MovieMetadata]
  /// Whether TMDb reports additional result pages.
  public let hasMorePages: Bool

  /// Creates a search result with its movies and pagination state.
  public init(movies: [MovieMetadata], hasMorePages: Bool) {
    self.movies = movies
    self.hasMorePages = hasMorePages
  }
}
