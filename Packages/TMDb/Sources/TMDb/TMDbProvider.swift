import Foundation
public import HTTPTransport
public import Contracts

/// Implements the shared movie provider contract using TMDb.
///
/// Adapts TMDb identity, evidence, and failures to shared provider values.
public struct TMDbProvider: MovieProviding {
  /// The configured provider client.
  private let client: TMDbClient

  /// Creates the live service with an optional privacy-safe request observer.
  public init(token: String, requestDelegate: (any ProviderRequestDelegate)? = .none) throws {
    try self.init(token: token, transport: URLSessionTransport(), requestDelegate: requestDelegate)
  }

  /// Validates bearer token syntax without making a request.
  public static func validateAccessToken(_ token: String) throws { _ = try makeAccessToken(token) }

  #if DEBUG
    /// Creates an isolated service that resolves requests against bundled fixtures.
    public init(token: String, fixturePosterData: Data) throws {
      try self.init(token: token, transport: StubTMDbTransport(posterData: fixturePosterData), requestDelegate: .none)
    }
  #endif

  /// Creates a provider with an injected HTTP transport.
  public init(
    token: String, transport: any HTTPTransport, requestDelegate: (any ProviderRequestDelegate)? = .none
  ) throws {
    client = TMDbClient(token: try Self.makeAccessToken(token), transport: transport,
      requestDelegate: requestDelegate.map { TMDbRequestDelegateAdapter(delegate: $0) })
  }

  /// Verifies the configured access token with the selected provider.
  public func validateAccessToken() async throws { try await perform { try await client.validateAccessToken() } }

  /// Returns one provider page and its pagination evidence.
  public func searchMoviePage(
    title: String, year: Int?, language: ProviderLanguage, page: Int
  ) async throws -> ProviderMoviePage {
    try await perform {
      let result = try await client.searchMoviePage(
        title: title, year: year, language: TMDbLanguage(language.rawValue), page: page)

      return ProviderMoviePage(movies: result.movies.map { mapMovie($0) }, page: result.page,
        totalPages: result.totalPages)
    }
  }

  /// Resolves one reference without falling back to title search.
  public func movie(
    identifiedBy reference: ProviderMovieReference, language: ProviderLanguage
  ) async throws -> ProviderMovie? {
    try await perform {
      let language = try TMDbLanguage(language.rawValue)
      let result = switch reference {
      case .tmdb(let id): try await client.movie(movieID: id, language: language)
      case .imdb(let id): try await client.movie(imdbID: id, language: language)
      }

      return result.map { mapMovie($0) }
    }
  }

  /// Returns complete alternative title evidence for a movie returned by this service.
  public func alternativeTitles(for reference: ProviderMovieReference) async throws -> [ProviderAlternativeTitle] {
    let id = try tmdbMovieID(for: reference)

    return try await perform {
      let result = try await client.alternativeTitles(movieID: id)
      guard let titles = result[id] else { throw MovieProviderError.malformedResponse }

      return titles.map { ProviderAlternativeTitle(countryCode: $0.countryCode, title: $0.title, type: $0.type) }
    }
  }

  /// Returns complete dated release evidence for a movie returned by this service.
  public func releaseDates(for reference: ProviderMovieReference) async throws -> [ProviderReleaseDate] {
    let id = try tmdbMovieID(for: reference)

    return try await perform {
      let result = try await client.releaseDates(movieID: id)
      guard let dates = result[id] else { throw MovieProviderError.malformedResponse }

      // TMDb event codes match the shared classification, including unclassified positive values.
      return dates.map { ProviderReleaseDate(countryCode: $0.countryCode, timestamp: $0.timestamp, type: $0.type) }
    }
  }

  /// Downloads validated source artwork.
  public func downloadPoster(_ reference: ProviderArtworkReference) async throws -> Data {
    switch reference {
    case .tmdb(let path): try await perform { try await client.downloadPoster(path: path) }
    }
  }

  private func mapMovie(_ movie: MovieMetadata) -> ProviderMovie {
    ProviderMovie(reference: .tmdb(movie.id), title: movie.title, originalTitle: movie.originalTitle,
      releaseYear: movie.releaseYear, artwork: movie.posterPath.map { .tmdb(path: $0) })
  }

  private func tmdbMovieID(for reference: ProviderMovieReference) throws -> Int {
    guard case .tmdb(let id) = reference else { throw MovieProviderError.invalidQuery }

    return id
  }

  private static func makeAccessToken(_ token: String) throws -> TMDbAccessToken {
    do {
      return try TMDbAccessToken(token)
    } catch let error as TMDbError {
      throw MovieProviderError(error)
    }
  }

  private func perform<Result>(_ operation: () async throws -> Result) async throws -> Result {
    do {
      return try await operation()
    } catch let error as TMDbError {
      throw MovieProviderError(error)
    }
  }
}

private extension MovieProviderError {
  init(_ error: TMDbError) {
    self = switch error {
    case .missingToken: .missingToken
    case .invalidQuery: .invalidQuery
    case .authentication: .authentication
    case .rateLimited(let retryAfter): .rateLimited(retryAfter: retryAfter)
    case .httpStatus(let statusCode): .httpStatus(statusCode)
    case .malformedResponse: .malformedResponse
    case .invalidPosterPath: .invalidPosterPath
    case .invalidImage: .invalidImage
    case .invalidConfiguration: .invalidConfiguration
    case .responseTooLarge: .responseTooLarge
    case .transport(let code): .transport(code: code)
    }
  }
}
