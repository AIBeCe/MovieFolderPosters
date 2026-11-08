import Foundation
import Network

/// Adapts movie network operations to the application's metadata and recovery contracts.
nonisolated public struct NetworkClient: MovieMetadataProvider {
  /// Configured module service used for every operation in this scope.
  private let service: any MovieNetworkServicing

  /// Creates the adapter over a configured module service.
  init(service: any MovieNetworkServicing) { self.service = service }

  /// Configures live access using the saved token and optional request observer.
  public init(token: String, requestDelegate: (any MovieNetworkRequestDelegate)? = .none) throws {
    let observer = requestDelegate.map { MovieNetworkRequestAdapter(delegate: $0) }
    self.init(service: try MovieNetworkErrorAdapter().perform {
      try MovieNetworkService(token: token, requestDelegate: observer)
    })
  }

  #if DEBUG
    /// Uses explicit fixture data and omits live request observation.
    public init(token: String, fixturePosterData: Data) throws {
      self.init(service: try MovieNetworkErrorAdapter().perform {
        try MovieNetworkService(token: token, fixturePosterData: fixturePosterData)
      })
    }
  #endif

  /// Verifies the configured access token.
  public func validateAccessToken() async throws {
    do { try await service.validateAccessToken() }
    catch let error as MovieNetworkError { throw MovieNetworkErrorAdapter().map(error) }
  }

  /// Fetches a single page, leaving aggregation and search limits with the application.
  public func searchMoviePage(
    title: String, year: Int?, language: MovieSearchLanguage, page: Int
  ) async throws -> MovieSearchPage {
    do {
      let result = try await service.searchMoviePage(
        title: title, year: year, language: NetworkLanguage(language.rawValue), page: page)

      return try MovieSearchPage(movies: result.movies.map(mapMovie), page: result.page, totalPages: result.totalPages)
    } catch let error as MovieNetworkError {
      throw MovieNetworkErrorAdapter().map(error)
    }
  }

  /// Resolves a saved TMDb identity without interpreting it in another provider's namespace.
  public func movie(movieID: Int, language: MovieSearchLanguage) async throws -> MovieMetadata? {
    try await movie(identifiedBy: .tmdb(movieID), language: language)
  }

  /// Resolves an explicit IMDb identifier through the configured module service.
  public func movie(imdbID: String, language: MovieSearchLanguage) async throws -> MovieMetadata? {
    try await movie(identifiedBy: .imdb(imdbID), language: language)
  }

  /// Returns complete title evidence under the requested legacy movie identity.
  public func alternativeTitles(movieID: Int) async throws -> MovieAlternativeTitlesByID {
    do {
      let titles = try await service.alternativeTitles(for: .tmdb(movieID))

      let evidence = titles.map {
        MovieAlternativeTitle(countryCode: $0.countryCode, title: $0.title, type: $0.type)
      }

      return [movieID: evidence]
    } catch let error as MovieNetworkError {
      throw MovieNetworkErrorAdapter().map(error)
    }
  }

  /// Returns complete dated evidence under the requested legacy movie identity.
  public func releaseDates(movieID: Int) async throws -> MovieReleaseDatesByID {
    do {
      let dates = try await service.releaseDates(for: .tmdb(movieID))

      return [movieID: try dates.map {
        try MovieReleaseDate(countryCode: $0.countryCode, timestamp: $0.timestamp, type: $0.type)
      }]
    } catch let error as MovieNetworkError {
      throw MovieNetworkErrorAdapter().map(error)
    }
  }

  /// Reads artwork whose legacy stored path belongs to TMDb.
  public func downloadPoster(path: String) async throws -> Data {
    do { return try await service.downloadPoster(.tmdb(path: path)) }
    catch let error as MovieNetworkError { throw MovieNetworkErrorAdapter().map(error) }
  }

  private func movie(
    identifiedBy reference: NetworkMovieReference, language: MovieSearchLanguage
  ) async throws -> MovieMetadata? {
    do {
      let movie = try await service.movie(identifiedBy: reference, language: NetworkLanguage(language.rawValue))

      return try movie.map(mapMovie)
    } catch let error as MovieNetworkError {
      throw MovieNetworkErrorAdapter().map(error)
    }
  }

  /// Projects only identities representable in the existing TMDb cache format.
  private func mapMovie(_ movie: NetworkMovie) throws -> MovieMetadata {
    guard case .tmdb(let id) = movie.reference else { throw MovieMetadataError.invalidConfiguration }

    let posterPath: String?
    switch movie.artwork {
    case .tmdb(let path): posterPath = path
    case .none: posterPath = .none
    }

    return MovieMetadata(id: id, title: movie.title, originalTitle: movie.originalTitle,
      releaseYear: movie.releaseYear, posterPath: posterPath)
  }
}

/// Validates a candidate access token without exposing its network implementation to a feature.
nonisolated public protocol ProviderAccessTokenValidating: Sendable {
  /// Verifies the supplied token without changing saved access tokens.
  func validateAccessToken(_ token: String) async throws
}

/// Configures a client for the particular access token being tested.
nonisolated public struct NetworkAccessTokenValidator: ProviderAccessTokenValidating {
  /// Observer shared with the client created for an access token check.
  private let requestDelegate: (any MovieNetworkRequestDelegate)?

  /// Creates a validator with optional privacy-safe request recording.
  public init(requestDelegate: (any MovieNetworkRequestDelegate)? = .none) { self.requestDelegate = requestDelegate }

  /// Checks token syntax without sending a request.
  public func validateAccessToken(_ token: String) throws {
    try MovieNetworkErrorAdapter().perform { try MovieNetworkService.validateAccessToken(token) }
  }

  /// Checks the token through the provider selected by Network.
  public func validateAccessToken(_ token: String) async throws {
    try await NetworkClient(token: token, requestDelegate: requestDelegate).validateAccessToken()
  }
}
