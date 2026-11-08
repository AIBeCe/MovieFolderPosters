/// A movie identity in the namespace that issued it.
public enum NetworkMovieReference: Equatable, Hashable, Sendable {
  /// A numeric identity issued by TMDb.
  case tmdb(Int)
  /// An IMDb title identifier accepted by explicit lookup.
  case imdb(String)
}

/// A provider-scoped artwork location.
public enum NetworkArtworkReference: Equatable, Hashable, Sendable {
  /// A path relative to the TMDb image service.
  case tmdb(path: String)
}

/// Movie metadata projected through the network contract.
public struct NetworkMovie: Equatable, Sendable {
  /// The movie's identity in its original namespace.
  public let reference: NetworkMovieReference
  /// The movie title in the requested language.
  public let title: String
  /// The title in the movie's original language.
  public let originalTitle: String
  /// The validated primary release year, if supplied.
  public let releaseYear: Int?
  /// The source artwork reference, if supplied.
  public let artwork: NetworkArtworkReference?

  /// Creates a movie result from provider evidence.
  public init(
    reference: NetworkMovieReference, title: String, originalTitle: String,
    releaseYear: Int?, artwork: NetworkArtworkReference?
  ) {
    self.reference = reference
    self.title = title
    self.originalTitle = originalTitle
    self.releaseYear = releaseYear
    self.artwork = artwork
  }
}

/// One validated search page with provider pagination evidence.
public struct NetworkMoviePage: Equatable, Sendable {
  /// The results in provider order.
  public let movies: [NetworkMovie]
  /// The one-based page index.
  public let page: Int
  /// The number of pages the provider reported.
  public let totalPages: Int

  /// Creates a search page from the supplied results and pagination.
  public init(movies: [NetworkMovie], page: Int, totalPages: Int) {
    self.movies = movies
    self.page = page
    self.totalPages = totalPages
  }
}

/// An alternative title with its source provenance.
public struct NetworkAlternativeTitle: Equatable, Sendable {
  /// The country associated with this spelling.
  public let countryCode: String
  /// The complete provider title.
  public let title: String
  /// The source classification, which may be empty.
  public let type: String

  /// Creates alternative title evidence without changing its spelling or provenance.
  public init(countryCode: String, title: String, type: String) {
    self.countryCode = countryCode
    self.title = title
    self.type = type
  }
}

/// A dated release event with its original provider provenance.
public struct NetworkReleaseDate: Equatable, Sendable {
  /// The two-letter country code.
  public let countryCode: String
  /// The validated original timestamp with its timezone.
  public let timestamp: String
  /// The canonical network release classification.
  ///
  /// Codes 1–6 mean premiere, limited theatrical, theatrical, digital, physical, and television, respectively.
  /// Other positive codes are unclassified. Provider adapters map native classifications to this vocabulary.
  public let type: Int

  /// Creates evidence from a validated provider release event.
  public init(countryCode: String, timestamp: String, type: Int) {
    self.countryCode = countryCode
    self.timestamp = timestamp
    self.type = type
  }
}
