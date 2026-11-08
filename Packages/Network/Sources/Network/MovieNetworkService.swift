import Foundation
internal import Contracts

/// Adapts the configured provider to the public Network contract.
public struct MovieNetworkService: MovieNetworkServicing {
  /// Supplies movie information and artwork for this service scope.
  private let provider: any MovieProviding

  /// Creates the service over a provider that fulfills the shared contract.
  init(provider: any MovieProviding) { self.provider = provider }

  /// Verifies the configured access token with the selected provider.
  public func validateAccessToken() async throws { try await perform { try await provider.validateAccessToken() } }

  /// Returns one provider page and its pagination evidence.
  public func searchMoviePage(
    title: String, year: Int?, language: NetworkLanguage, page: Int
  ) async throws -> NetworkMoviePage {
    try await perform {
      let result = try await provider.searchMoviePage(
        title: title, year: year, language: ProviderLanguage(language.rawValue), page: page)

      return NetworkMoviePage(movies: result.movies.map(mapMovie), page: result.page, totalPages: result.totalPages)
    }
  }

  /// Resolves one reference without falling back to title search.
  public func movie(
    identifiedBy reference: NetworkMovieReference, language: NetworkLanguage
  ) async throws -> NetworkMovie? {
    try await perform {
      let result = try await provider.movie(
        identifiedBy: providerReference(reference), language: ProviderLanguage(language.rawValue))

      return result.map(mapMovie)
    }
  }

  /// Returns complete alternative title evidence for a movie returned by this service.
  public func alternativeTitles(for reference: NetworkMovieReference) async throws -> [NetworkAlternativeTitle] {
    try await perform {
      let titles = try await provider.alternativeTitles(for: providerReference(reference))

      return titles.map { NetworkAlternativeTitle(countryCode: $0.countryCode, title: $0.title, type: $0.type) }
    }
  }

  /// Returns complete dated release evidence for a movie returned by this service.
  public func releaseDates(for reference: NetworkMovieReference) async throws -> [NetworkReleaseDate] {
    try await perform {
      let dates = try await provider.releaseDates(for: providerReference(reference))

      return dates.map { NetworkReleaseDate(countryCode: $0.countryCode, timestamp: $0.timestamp, type: $0.type) }
    }
  }

  /// Downloads validated source artwork.
  public func downloadPoster(_ reference: NetworkArtworkReference) async throws -> Data {
    try await perform { try await provider.downloadPoster(providerArtwork(reference)) }
  }

  private func mapMovie(_ movie: ProviderMovie) -> NetworkMovie {
    let reference: NetworkMovieReference = switch movie.reference {
    case .tmdb(let id): .tmdb(id)
    case .imdb(let id): .imdb(id)
    }
    let artwork: NetworkArtworkReference? = switch movie.artwork {
    case .tmdb(let path): .tmdb(path: path)
    case .none: .none
    }

    return NetworkMovie(reference: reference, title: movie.title, originalTitle: movie.originalTitle,
      releaseYear: movie.releaseYear, artwork: artwork)
  }

  private func providerReference(_ reference: NetworkMovieReference) -> ProviderMovieReference {
    switch reference {
    case .tmdb(let id): .tmdb(id)
    case .imdb(let id): .imdb(id)
    }
  }

  private func providerArtwork(_ reference: NetworkArtworkReference) -> ProviderArtworkReference {
    switch reference {
    case .tmdb(let path): .tmdb(path: path)
    }
  }

  private func perform<Result>(_ operation: () async throws -> Result) async throws -> Result {
    do {
      return try await operation()
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as MovieProviderError {
      throw MovieNetworkError(error)
    } catch {
      throw MovieNetworkError.invalidConfiguration
    }
  }
}

extension MovieNetworkError {
  init(_ error: MovieProviderError) {
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
