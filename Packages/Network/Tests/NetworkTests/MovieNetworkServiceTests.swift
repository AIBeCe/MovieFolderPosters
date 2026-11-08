import Foundation
@_spi(Testing) import Network
import Testing

/// Exercises the exported service through provider responses that never leave the process.
struct MovieNetworkServiceTests {
  @Test func searchMapsProviderIdentityAndArtwork() async throws {
    let body = """
      {"page":1,"total_pages":2,"results":[{"id":42,"title":"Dune","original_title":"Dune",
        "release_date":"2021-09-15","poster_path":"/dune.jpg"}]}
      """
    let service = try MovieNetworkService(token: "fixture", testTransport: ScriptedTransport(body: body))

    let page = try await service.searchMoviePage(title: "Dune", year: 2021, language: .english, page: 1)

    #expect(page.page == 1)
    #expect(page.totalPages == 2)
    #expect(page.movies == [
      NetworkMovie(reference: .tmdb(42), title: "Dune", originalTitle: "Dune", releaseYear: 2021,
        artwork: .tmdb(path: "/dune.jpg"))
    ])
  }

  @Test func lookupDistinguishesDefinitiveMissFromFailure() async throws {
    let missing = try MovieNetworkService(
      token: "fixture", testTransport: ScriptedTransport(body: #"{"movie_results":[]}"#))
    let throttled = try MovieNetworkService(
      token: "fixture", testTransport: ScriptedTransport(statusCode: 429, retryAfter: "60"))

    #expect(try await missing.movie(identifiedBy: .imdb("tt1160419"), language: .english) == nil)
    await #expect(throws: MovieNetworkError.rateLimited(retryAfter: "60")) {
      try await throttled.movie(identifiedBy: .tmdb(42), language: .english)
    }
  }

  @Test func preservesCompleteEvidenceForCanonicalIdentity() async throws {
    let titles = try MovieNetworkService(token: "fixture", testTransport: ScriptedTransport(body:
      #"{"id":42,"titles":[{"iso_3166_1":"FR","title":"Dune","type":"theatrical"}]}"#))
    let dates = try MovieNetworkService(token: "fixture", testTransport: ScriptedTransport(body:
      """
      {"id":42,"results":[{"iso_3166_1":"US",
        "release_dates":[{"release_date":"2021-09-15T00:00:00.000Z","type":3},
          {"release_date":"2021-10-15T00:00:00.000Z","type":91}]}]}
      """))

    #expect(try await titles.alternativeTitles(for: .tmdb(42)) == [
      NetworkAlternativeTitle(countryCode: "FR", title: "Dune", type: "theatrical")
    ])
    #expect(try await dates.releaseDates(for: .tmdb(42)) == [
      NetworkReleaseDate(countryCode: "US", timestamp: "2021-09-15T00:00:00.000Z", type: 3),
      NetworkReleaseDate(countryCode: "US", timestamp: "2021-10-15T00:00:00.000Z", type: 91)
    ])
    await #expect(throws: MovieNetworkError.invalidQuery) {
      try await titles.alternativeTitles(for: .imdb("tt1160419"))
    }
    await #expect(throws: MovieNetworkError.invalidQuery) {
      try await dates.releaseDates(for: .imdb("tt1160419"))
    }
  }

  @Test func requestObservationRetainsOriginalCategoryResultAndTicket() async throws {
    let delegate = RequestRecordingDelegate()
    let service = try MovieNetworkService(token: "fixture", testTransport: ScriptedTransport(statusCode: 401),
      requestDelegate: delegate)

    await #expect(throws: MovieNetworkError.authentication) { try await service.validateAccessToken() }

    #expect(await delegate.requestPurposes == [.accessTokenValidation])
    #expect(await delegate.completions == [
      RequestRecordingDelegate.Completion(purpose: .accessTokenValidation, result: .response(statusCode: 401),
        ticket: delegate.ticket)
    ])
  }

  #if DEBUG
    @Test func fixtureModeResolvesKnownMovieThroughPublicContract() async throws {
      let service = try MovieNetworkService(token: "fixture", fixturePosterData: Data())

      let movie = try await service.movie(identifiedBy: .imdb("tt0000001"), language: .english)

      #expect(movie?.reference == .tmdb(1))
      #expect(movie?.title == "The Last Frame")
      #expect(movie?.artwork == .tmdb(path: "/test-poster.png"))
    }
  #endif

  @Test func cancelledRequestRemainsCancellation() async throws {
    let service = try MovieNetworkService(token: "fixture", testTransport: ScriptedTransport())
    let request = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await service.validateAccessToken()
    }

    await #expect(throws: CancellationError.self) { try await request.value }
  }

  @Test func invalidAccessTokenIsTranslatedAtConstruction() {
    #expect(throws: MovieNetworkError.missingToken) { try MovieNetworkService(token: "") }
  }
}

/// Supplies one deterministic wire response at the public service boundary.
private struct ScriptedTransport: NetworkTestTransport {
  var body = "{}"
  var statusCode = 200
  var retryAfter: String? = .none

  func send(_ request: URLRequest) async throws -> NetworkTestResponse {
    NetworkTestResponse(data: Data(body.utf8), statusCode: statusCode, contentType: "application/json",
      retryAfter: retryAfter)
  }
}

/// Records boundary observations using a stable ticket supplied by the observer.
private actor RequestRecordingDelegate: NetworkRequestDelegate {
  struct Completion: Equatable {
    let purpose: NetworkRequestCategory
    let result: NetworkRequestCompletionResult
    let ticket: UUID
  }

  let ticket = UUID()
  private(set) var requestPurposes: [NetworkRequestCategory] = []
  private(set) var completions: [Completion] = []

  func networkWillSendRequest(purpose: NetworkRequestCategory) -> UUID? {
    requestPurposes.append(purpose)

    return ticket
  }

  func networkDidCompleteRequest(
    purpose: NetworkRequestCategory, result: NetworkRequestCompletionResult, completedAt: Date, recordingTicket: UUID
  ) {
    completions.append(Completion(purpose: purpose, result: result, ticket: recordingTicket))
  }
}
