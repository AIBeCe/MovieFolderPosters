import Foundation
import Contracts
@testable import Network
import Testing

/// The existing Network API uses the selected provider and preserves its reference namespace.
@Test func movieNetworkServiceUsesInjectedProvider() async throws {
  let provider = AlternateMovieProvider()
  let service: any MovieNetworkServicing = MovieNetworkService(provider: provider)

  let page = try await service.searchMoviePage(
    title: "Fixture", year: 2024, language: NetworkLanguage("pt-BR"), page: 2)
  let movie = try await service.movie(identifiedBy: .imdb("tt0000001"), language: .english)

  #expect(page.page == 2)
  #expect(page.totalPages == 2)
  #expect(page.movies.map(\.title) == ["Alternate provider"])
  #expect(movie?.reference == .imdb("tt0000001"))
  #expect(movie?.title == "Alternate provider")
  #expect(await provider.searchLanguages == ["pt-BR"])
  #expect(await provider.lookups == [.imdb("tt0000001")])
}

/// Sanitizes failures from a conformer that does not use the shared error vocabulary.
@Test func movieNetworkServiceContainsUnexpectedProviderFailures() async throws {
  let provider = AlternateMovieProvider(accessTokenError: UnexpectedProviderFailure())
  let service: any MovieNetworkServicing = MovieNetworkService(provider: provider)

  await #expect(throws: MovieNetworkError.invalidConfiguration) { try await service.validateAccessToken() }
}

private struct UnexpectedProviderFailure: Error {}

/// Supplies deterministic metadata without constructing a concrete provider or sending HTTP.
private actor AlternateMovieProvider: MovieProviding {
  private(set) var searchLanguages: [String] = []
  private(set) var lookups: [ProviderMovieReference] = []

  private let result = ProviderMovie(reference: .imdb("tt0000001"), title: "Alternate provider",
    originalTitle: "Alternate provider", releaseYear: 2024, artwork: .none)

  private let accessTokenError: (any Error)?

  init(accessTokenError: (any Error)? = .none) { self.accessTokenError = accessTokenError }

  func validateAccessToken() throws {
    if let accessTokenError { throw accessTokenError }
  }

  func searchMoviePage(title: String, year: Int?, language: ProviderLanguage, page: Int) -> ProviderMoviePage {
    searchLanguages.append(language.rawValue)

    return ProviderMoviePage(movies: [result], page: page, totalPages: 2)
  }

  func movie(identifiedBy reference: ProviderMovieReference, language: ProviderLanguage) -> ProviderMovie? {
    lookups.append(reference)

    return reference == result.reference ? result : .none
  }

  func alternativeTitles(for reference: ProviderMovieReference) -> [ProviderAlternativeTitle] { [] }
  func releaseDates(for reference: ProviderMovieReference) -> [ProviderReleaseDate] { [] }
  func downloadPoster(_ reference: ProviderArtworkReference) throws -> Data { throw MovieProviderError.invalidQuery }
}
