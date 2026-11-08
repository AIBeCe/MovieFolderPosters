import Foundation
import Network
import Testing

@testable import Common

/// Invalid access tokens are rejected at construction with the app's error contract.
@Test func networkClientRejectsEmptyAccessTokenStore() {
  #expect(throws: MovieMetadataError.missingToken) {
    try NetworkClient(token: "")
  }
}

/// A confirmed lookup projects the legacy TMDb ID and poster path without a title search.
@Test func networkClientMapsExplicitLookup() async throws {
  let movie = NetworkMovie(reference: .tmdb(42), title: "Dune", originalTitle: "Dune",
    releaseYear: 2021, artwork: .tmdb(path: "/dune.jpg"))
  let service = MovieNetworkServiceProbe(lookup: .success(movie))
  let client = NetworkClient(service: service)

  let result = try await client.movie(imdbID: "tt1160419", language: MovieSearchLanguage("pt-BR"))

  #expect(result == MovieMetadata(id: 42, title: "Dune", originalTitle: "Dune",
    releaseYear: 2021, posterPath: "/dune.jpg"))
  #expect(await service.references == [.imdb("tt1160419")])
  #expect(await service.languages == ["pt-BR"])
}

/// A definitive miss remains distinct from a rate limit or cancellation.
@Test func networkClientPreservesLookupOutcomes() async throws {
  let miss = NetworkClient(service: MovieNetworkServiceProbe(lookup: .success(nil)))
  #expect(try await miss.movie(movieID: 42, language: .english) == nil)

  let limited = NetworkClient(service: MovieNetworkServiceProbe(lookup: .failure(MovieNetworkError.rateLimited(
    retryAfter: "60"))))
  await #expect(throws: MovieMetadataError.rateLimited(retryAfter: "60")) {
    try await limited.movie(movieID: 42, language: .english)
  }

  let cancelled = NetworkClient(service: MovieNetworkServiceProbe(lookup: .failure(CancellationError())))
  await #expect(throws: CancellationError.self) { try await cancelled.movie(movieID: 42, language: .english) }
}

/// A provider identity that the current persisted format cannot represent is rejected.
@Test func networkClientDoesNotPersistIMDbIdentityAsTMDb() async throws {
  let movie = NetworkMovie(reference: .imdb("tt1160419"), title: "Dune", originalTitle: "Dune",
    releaseYear: 2021, artwork: nil)
  let client = NetworkClient(service: MovieNetworkServiceProbe(lookup: .success(movie)))

  await #expect(throws: MovieMetadataError.invalidConfiguration) {
    try await client.movie(imdbID: "tt1160419", language: .english)
  }
}

/// Supplies a controlled result and records the inputs received at the module boundary.
private actor MovieNetworkServiceProbe: MovieNetworkServicing {
  private let lookup: Result<NetworkMovie?, any Error>
  private(set) var references: [NetworkMovieReference] = []
  private(set) var languages: [String] = []

  init(lookup: Result<NetworkMovie?, any Error>) { self.lookup = lookup }

  func validateAccessToken() throws { throw MovieNetworkError.invalidConfiguration }

  func searchMoviePage(title: String, year: Int?, language: NetworkLanguage, page: Int) throws -> NetworkMoviePage {
    throw MovieNetworkError.invalidConfiguration
  }

  func movie(identifiedBy reference: NetworkMovieReference, language: NetworkLanguage) throws -> NetworkMovie? {
    references.append(reference)
    languages.append(language.rawValue)

    return try lookup.get()
  }

  func alternativeTitles(for reference: NetworkMovieReference) throws -> [NetworkAlternativeTitle] {
    throw MovieNetworkError.invalidConfiguration
  }

  func releaseDates(for reference: NetworkMovieReference) throws -> [NetworkReleaseDate] {
    throw MovieNetworkError.invalidConfiguration
  }

  func downloadPoster(_ reference: NetworkArtworkReference) throws -> Data {
    throw MovieNetworkError.invalidConfiguration
  }
}

/// A completion reaches app history with the same ticket, request kind, timestamp, and status.
@Test func networkClientPreservesRequestObservationEvidence() async throws {
  let delegate = MovieNetworkRequestProbe()
  let adapter = MovieNetworkRequestAdapter(delegate: delegate)
  let ticket = try #require(await adapter.networkWillSendRequest(purpose: .movieLookup))
  let completedAt = Date(timeIntervalSince1970: 1_800_000_000)

  await adapter.networkDidCompleteRequest(
    purpose: .movieLookup, result: .response(statusCode: 404), completedAt: completedAt, recordingTicket: ticket)

  let completion = try #require(await delegate.completion)
  #expect(completion.purpose == .movieLookup)
  #expect(completion.result == .response(statusCode: 404))
  #expect(completion.completedAt == completedAt)
  #expect(completion.ticket == ticket)
}

private actor MovieNetworkRequestProbe: MovieNetworkRequestDelegate {
  private let ticket = UUID()
  private(set) var completion: (
    purpose: MovieNetworkRequestCategory, result: MovieNetworkRequestResult, completedAt: Date, ticket: UUID
  )?

  func movieNetworkWillSendRequest(purpose: MovieNetworkRequestCategory) -> UUID? { ticket }

  func movieNetworkDidCompleteRequest(
    purpose: MovieNetworkRequestCategory, result: MovieNetworkRequestResult, completedAt: Date, recordingTicket: UUID
  ) {
    completion = (purpose, result, completedAt, recordingTicket)
  }
}
