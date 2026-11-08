import Foundation
import HTTPTransport
import Contracts
import Testing
import TMDb

/// Exercises the standalone provider through the shared movie contract.
struct TMDbProviderTests {
  @Test func lookupMapsIdentityAndArtworkThroughSharedContract() async throws {
    let transport = ScriptedHTTPTransport([.success(response("""
      {"movie_results":[{"id":42,"title":"Dune","original_title":"Dune",
        "release_date":"2021-09-15","poster_path":"/dune.jpg"}]}
      """))])
    let provider: any MovieProviding = try TMDbProvider(token: "fixture", transport: transport)

    let result = try await provider.movie(identifiedBy: .imdb("tt1160419"), language: .english)

    #expect(result == ProviderMovie(reference: .tmdb(42), title: "Dune", originalTitle: "Dune", releaseYear: 2021,
      artwork: .tmdb(path: "/dune.jpg")))
    #expect(await transport.capturedRequests().map { $0.url?.path } == ["/3/find/tt1160419"])
  }

  @Test func requestFailurePreservesProviderRetryEvidence() async throws {
    let retry = HTTPTransportResponse(data: .init(), statusCode: 429, contentType: "application/json",
      retryAfter: "60")
    let transport = ScriptedHTTPTransport([.success(retry)])
    let provider: any MovieProviding = try TMDbProvider(token: "fixture", transport: transport)

    await #expect(throws: MovieProviderError.rateLimited(retryAfter: "60")) {
      try await provider.validateAccessToken()
    }
  }

  @Test func providerArtworkPreservesBytesAndRequestEvidence() async throws {
    let image = try validPNG()
    let configuration = response(
      #"{"images":{"secure_base_url":"https://image.tmdb.org/t/p/","poster_sizes":["w500"]}}"#)
    let transport = ScriptedHTTPTransport([
      .success(configuration),
      .success(HTTPTransportResponse(data: image, statusCode: 200, contentType: "image/png"))
    ])
    let delegate = ProviderRequestRecorder()
    let provider: any MovieProviding = try TMDbProvider(
      token: "fixture", transport: transport, requestDelegate: delegate)

    let data = try await provider.downloadPoster(.tmdb(path: "/p.png"))

    #expect(data == image)
    let requests = await transport.capturedRequests()
    #expect(requests.map { $0.url?.host } == ["api.themoviedb.org", "image.tmdb.org"])
    #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == nil)
    let observation = await delegate.observation
    #expect(observation.map(\.purpose) == [.posterConfiguration, .posterDownload])
    #expect(observation.map(\.result) == [.response(statusCode: 200), .response(statusCode: 200)])
    #expect(observation.map(\.ticket) == (await delegate.prepared))
  }

  @Test func evidencePreservesEmptyTitlesAndCanonicalReleaseCodes() async throws {
    let transport = ScriptedHTTPTransport([
      .success(response(#"{"id":42,"titles":[]}"#)),
      .success(response("""
        {"id":42,"results":[{"iso_3166_1":"US",
          "release_dates":[{"release_date":"2021-09-15T00:00:00Z","type":3},
            {"release_date":"2021-10-15T00:00:00Z","type":91}]}]}
        """))
    ])
    let provider: any MovieProviding = try TMDbProvider(token: "fixture", transport: transport)

    #expect(try await provider.alternativeTitles(for: .tmdb(42)).isEmpty)
    let dates = try await provider.releaseDates(for: .tmdb(42))
    #expect(dates.map(\.type) == [3, 91])
    #expect(dates.map(\.countryCode) == ["US", "US"])
  }
}

/// Captures tickets before dispatch and the corresponding completion events.
private actor ProviderRequestRecorder: ProviderRequestDelegate {
  private(set) var prepared: [UUID] = []
  private(set) var observation: [
    (purpose: ProviderRequestCategory, result: ProviderRequestCompletionResult, ticket: UUID)
  ] = []

  func providerWillSendRequest(purpose: ProviderRequestCategory) -> UUID? {
    let ticket = UUID()
    prepared.append(ticket)

    return ticket
  }

  func providerDidCompleteRequest(
    purpose: ProviderRequestCategory, result: ProviderRequestCompletionResult, completedAt: Date, recordingTicket: UUID
  ) {
    observation.append((purpose, result, recordingTicket))
  }
}
