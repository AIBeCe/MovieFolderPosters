/// A movie identity in the namespace that issued it.
public enum ProviderMovieReference: Equatable, Hashable, Sendable {
  /// A numeric identity issued by TMDb.
  case tmdb(Int)
  /// An IMDb title identifier accepted by explicit lookup.
  case imdb(String)
}

/// A provider-scoped artwork location.
public enum ProviderArtworkReference: Equatable, Hashable, Sendable {
  /// A path relative to the TMDb image service.
  case tmdb(path: String)
}

/// Movie metadata projected through the provider contract.
public struct ProviderMovie: Equatable, Sendable {
  /// The movie's identity in its original namespace.
  public let reference: ProviderMovieReference
  /// The movie title in the requested language.
  public let title: String
  /// The title in the movie's original language.
  public let originalTitle: String
  /// The validated primary release year, if supplied.
  public let releaseYear: Int?
  /// The source artwork reference, if supplied.
  public let artwork: ProviderArtworkReference?

  /// Creates a movie result from provider evidence.
  public init(
    reference: ProviderMovieReference, title: String, originalTitle: String,
    releaseYear: Int?, artwork: ProviderArtworkReference?
  ) {
    self.reference = reference
    self.title = title
    self.originalTitle = originalTitle
    self.releaseYear = releaseYear
    self.artwork = artwork
  }
}

/// One validated search page with provider pagination evidence.
public struct ProviderMoviePage: Equatable, Sendable {
  /// The results in provider order.
  public let movies: [ProviderMovie]
  /// The one-based page index.
  public let page: Int
  /// The number of pages the provider reported.
  public let totalPages: Int

  /// Creates a search page from the supplied results and pagination.
  public init(movies: [ProviderMovie], page: Int, totalPages: Int) {
    self.movies = movies
    self.page = page
    self.totalPages = totalPages
  }
}

/// An alternative title with its source provenance.
public struct ProviderAlternativeTitle: Equatable, Sendable {
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
public struct ProviderReleaseDate: Equatable, Sendable {
  /// The two-letter country code.
  public let countryCode: String
  /// The validated original timestamp with its timezone.
  public let timestamp: String
  /// The canonical provider contract release classification.
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
