import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

import HTTPTransport
@testable import TMDb

/// An actor-backed transport that returns queued responses and records submitted requests.
actor ScriptedHTTPTransport: HTTPTransport {
  /// Responses returned in request order.
  private var responses: [Result<HTTPTransportResponse, Error>]
  /// Requests received by the test subject.
  private(set) var requests: [URLRequest] = []

  /// Creates a transport with deterministic responses for each request.
  init(_ responses: [Result<HTTPTransportResponse, Error>]) {
    self.responses = responses
  }

  /// Records the request and returns the next queued response.
  func send(_ request: URLRequest) throws -> HTTPTransportResponse {
    requests.append(request)
    guard !responses.isEmpty else { throw URLError(.badServerResponse) }

    return try responses.removeFirst().get()
  }

  /// Returns the requests observed so far.
  func capturedRequests() -> [URLRequest] { requests }
}

/// Creates a JSON HTTP response with the requested status code.
func response(_ json: String, status: Int = 200) -> HTTPTransportResponse {
  HTTPTransportResponse(data: Data(json.utf8), statusCode: status, contentType: "application/json")
}

/// Generates a small encoded PNG for poster validation tests.
func validPNG() throws -> Data {
  let colorSpace = CGColorSpaceCreateDeviceRGB()
  let context = try #require(
    CGContext(
      data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
  context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
  context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
  let image = try #require(context.makeImage())
  let data = NSMutableData()
  let destination = try #require(
    CGImageDestinationCreateWithData(
      data, UTType.png.identifier as CFString, 1, nil))
  CGImageDestinationAddImage(destination, image, nil)
  precondition(CGImageDestinationFinalize(destination))

  return data as Data
}

/// Checks that exact-title results and first-page pagination metadata are mapped correctly.
@Test func searchMapsExactTitleAndReportsAdditionalPages() async throws {
  let transport = ScriptedHTTPTransport([
    .success(
      response(
        """
        {"page":1,"total_pages":2,"results":[{"id":42,"title":"Alien","original_title":"Alien",
        "release_date":"1979-05-25","poster_path":"/alien.jpg"}]}
        """))
  ])
  let client = try TMDbClient(token: TMDbAccessToken("secret-token"), transport: transport)

  let result = try await client.searchMoviePage(title: "Alien", year: 1979, page: 1)
  let requests = await transport.capturedRequests()
  let requestURL = try #require(requests.first?.url)
  let components = try #require(
    URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
  let queryItems = try #require(components.queryItems)
  let query = Dictionary(
    uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })

  #expect(
    result.movies == [
      MovieMetadata(
        id: 42, title: "Alien", originalTitle: "Alien",
        releaseYear: 1979, posterPath: "/alien.jpg")
    ])
  #expect((result.totalPages > result.page))
  #expect(components.host == "api.themoviedb.org")
  #expect(query["query"] == "Alien")
  #expect(query["year"] == "1979")
  #expect(query["include_adult"] == "false")
  #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
}

/// Checks that an empty TMDb response maps to an empty, final result page.
@Test func noResultsIsEmptyAndNotMorePages() async throws {
  let transport = ScriptedHTTPTransport([
    .success(response("{\"page\":1,\"total_pages\":0,\"results\":[]}"))
  ])
  let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
  let result = try await client.searchMoviePage(title: "missing", year: .none, page: 1)
  #expect(result.movies.isEmpty)
  #expect(!(result.totalPages > result.page))
}

/// Scenario: access token rejects empty and line breaks and redacts description.
@Test func accessTokenRejectsEmptyAndLineBreaksAndRedactsDescription() throws {
  #expect(throws: TMDbError.self) { try TMDbAccessToken("  ") }
  #expect(throws: TMDbError.self) { try TMDbAccessToken("x\r\nInjected: yes") }
  let token = try TMDbAccessToken("private-value")
  #expect(!String(describing: token).contains("private-value"))
}

/// Scenario: unauthorized status is typed and does not expose body.
@Test func unauthorizedStatusIsTypedAndDoesNotExposeBody() async throws {
  let transport = ScriptedHTTPTransport([
    .success(
      HTTPTransportResponse(
        data: Data("secret-body".utf8), statusCode: 401,
        contentType: "text/plain"))
  ])
  let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
  await #expect(throws: TMDbError.authentication) {
    try await client.searchMoviePage(title: "Alien", year: .none, page: 1)
  }
}

/// Scenario: auth failures are typed.
@Test(arguments: [401, 403])
func authFailuresAreTyped(status: Int) async throws {
  let transport = ScriptedHTTPTransport([.success(response("{}", status: status))])
  let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
  await #expect(throws: TMDbError.authentication) {
    try await client.searchMoviePage(title: "Alien", year: .none, page: 1)
  }
}

/// Scenario: rate limit carries retry after without body.
@Test func rateLimitCarriesRetryAfterWithoutBody() async throws {
  let transport = ScriptedHTTPTransport([
    .success(
      HTTPTransportResponse(
        data: Data("private response".utf8), statusCode: 429, contentType: "text/plain",
        retryAfter: "30"
      ))
  ])
  let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
  await #expect(throws: TMDbError.rateLimited(retryAfter: "30")) {
    try await client.searchMoviePage(title: "Alien", year: .none, page: 1)
  }
}

/// Scenario: other http failures preserve status.
@Test(arguments: [400, 500, 503])
func otherHTTPFailuresPreserveStatus(status: Int) async throws {
  let transport = ScriptedHTTPTransport([.success(response("private body", status: status))])
  let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
  await #expect(throws: TMDbError.httpStatus(status)) {
    try await client.searchMoviePage(title: "Alien", year: .none, page: 1)
  }
}

/// Scenario: transport failure is redacted and typed.
@Test func transportFailureIsRedactedAndTyped() async throws {
  let transport = ScriptedHTTPTransport([.failure(URLError(.notConnectedToInternet))])
  let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
  await #expect(throws: TMDbError.transport(code: URLError.notConnectedToInternet.rawValue)) {
    try await client.searchMoviePage(title: "Alien", year: .none, page: 1)
  }
}

/// Scenario: client rejects oversized injected transport response.
@Test func clientRejectsOversizedInjectedTransportResponse() async throws {
  let oversized = Data(repeating: 0x61, count: 10 * 1_024 * 1_024 + 1)
  let transport = ScriptedHTTPTransport([
    .success(
      HTTPTransportResponse(
        data: oversized, statusCode: 200,
        contentType: "application/json"))
  ])
  let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
  await #expect(throws: TMDbError.responseTooLarge) {
    try await client.searchMoviePage(title: "Alien", year: .none, page: 1)
  }
}

/// Checks that malformed or inconsistent search payloads fail response validation.
@Test(arguments: [
  "not-json",
  "{\"page\":1,\"total_pages\":1,\"results\":[{\"id\":0,\"title\":\"x\",\"original_title\":\"x\"}]}",
  """
  {"page":1,"total_pages":1,"results":[{"id":1,"title":"x","original_title":"x",
  "release_date":"2023-02-29"}]}
  """,
  """
  {"page":1,"total_pages":1,"results":[{"id":1,"title":"x","original_title":"x",
  "release_date":"2020-1-02"}]}
  """,
  "{\"page\":2,\"total_pages\":2,\"results\":[]}",
  "{\"page\":1,\"total_pages\":0,\"results\":[{\"id\":9,\"title\":\"x\",\"original_title\":\"x\"}]}"
])
func malformedSearchPayloadsAreRejected(json: String) async throws {
  let transport = ScriptedHTTPTransport([.success(response(json))])
  let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
  await #expect(throws: TMDbError.malformedResponse) {
    try await client.searchMoviePage(title: "Alien", year: .none, page: 1)
  }
}

/// Scenario: valid unknown date maps to nil and no auth leaks to poster request.
@Test func validUnknownDateMapsToNilAndNoAuthLeaksToPosterRequest() async throws {
  let configuration = HTTPTransportResponse(
    data: Data(
      """
      {"images":{"secure_base_url":"https://image.tmdb.org/t/p/","poster_sizes":["w185","w500"]}}
      """.utf8), statusCode: 200, contentType: "application/json")
  let png = try validPNG()
  let transport = ScriptedHTTPTransport([
    .success(
      response(
        """
        {"page":1,"total_pages":1,"results":[{"id":3,"title":"Unknown","original_title":"Unknown",
        "release_date":"","poster_path":"/p.png"}]}
        """)),
    .success(configuration),
    .success(HTTPTransportResponse(data: png, statusCode: 200, contentType: "image/png"))
  ])
  let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
  let search = try await client.searchMoviePage(title: "Unknown", year: .none, page: 1)
  #expect(search.movies.first?.releaseYear == .none)
  let downloaded = try await client.downloadPoster(path: "/p.png")
  #expect(downloaded == png)
  let requests = await transport.capturedRequests()
  #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer token")
  #expect(requests[2].url?.host == "image.tmdb.org")
  #expect(requests[2].value(forHTTPHeaderField: "Authorization") == .none)
}

/// Scenario: unsafe poster paths are rejected.
@Test(arguments: [
  "", "p.png", "/../p.png", "/%2e%2e/p.png", "/p.png?x=1", "//evil.test/p.png", "/a/b.png"
])
func unsafePosterPathsAreRejected(path: String) async throws {
  let transport = ScriptedHTTPTransport([])
  let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
  await #expect(throws: TMDbError.invalidPosterPath) { try await client.downloadPoster(path: path) }
  #expect(await transport.capturedRequests().isEmpty)
}

/// Scenario: invalid poster image is rejected.
@Test func invalidPosterImageIsRejected() async throws {
  let configuration = HTTPTransportResponse(
    data: Data(
      """
      {"images":{"secure_base_url":"https://image.tmdb.org/t/p/","poster_sizes":["w500"]}}
      """.utf8), statusCode: 200, contentType: "application/json")
  let transport = ScriptedHTTPTransport([
    .success(configuration),
    .success(HTTPTransportResponse(data: Data("not image".utf8), statusCode: 200, contentType: "image/png"))
  ])
  let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
  await #expect(throws: TMDbError.invalidImage) { try await client.downloadPoster(path: "/p.png") }
}

/// Scenario: truncated png is rejected.
@Test func truncatedPNGIsRejected() async throws {
  let configuration = HTTPTransportResponse(
    data: Data(
      """
      {"images":{"secure_base_url":"https://image.tmdb.org/t/p/","poster_sizes":["w500"]}}
      """.utf8), statusCode: 200, contentType: "application/json")
  let valid = try validPNG()
  let truncated = Data(valid.prefix(41))
  let transport = ScriptedHTTPTransport([
    .success(configuration),
    .success(HTTPTransportResponse(data: truncated, statusCode: 200, contentType: "image/png"))
  ])
  let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
  await #expect(throws: TMDbError.invalidImage) { try await client.downloadPoster(path: "/p.png") }
}

/// Scenario: untrusted image configuration is rejected.
@Test(arguments: [
  "https://evil.example/t/p/",
  "https://user:password@image.tmdb.org/t/p/",
  "https://image.tmdb.org:8443/t/p/",
  "https://image.tmdb.org/t/p/?x=y",
  "https://image.tmdb.org/t/p/#fragment"
])
func untrustedImageConfigurationIsRejected(baseURL: String) async throws {
  let json = """
    {"images":{"secure_base_url":"\(baseURL)","poster_sizes":["w500"]}}
    """
  let configuration = HTTPTransportResponse(
    data: Data(json.utf8), statusCode: 200,
    contentType: "application/json")
  let transport = ScriptedHTTPTransport([.success(configuration)])
  let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
  await #expect(throws: TMDbError.invalidConfiguration) { try await client.downloadPoster(path: "/p.png") }
  #expect(await transport.capturedRequests().count == 1)
}

/// Scenario: cancelled task is cancelled before sending.
@Test func cancelledTaskIsCancelledBeforeSending() async throws {
  let transport = ScriptedHTTPTransport([])
  let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
  let task = Task { @Sendable in
    withUnsafeCurrentTask { $0?.cancel() }

    return try await client.searchMoviePage(title: "Alien", year: .none, page: 1)
  }
  await #expect(throws: CancellationError.self) { try await task.value }
  #expect(await transport.capturedRequests().isEmpty)
}

/// Holds a request until the test releases it, allowing cancellation timing to be controlled.
actor SuspendedHTTPTransport: HTTPTransport {
  /// Suspended request continuation resumed with the controlled test response.
  private var responseContinuation: CheckedContinuation<HTTPTransportResponse, Never>?
  /// Suspended waiter resumed once a request has reached the transport.
  private var startedContinuation: CheckedContinuation<Void, Never>?
  /// Whether the transport has received its request.
  private var hasStarted = false

  /// Suspends until the test resumes this request with a response.
  func send(_ request: URLRequest) async throws -> HTTPTransportResponse {
    await withCheckedContinuation { continuation in
      responseContinuation = continuation
      hasStarted = true
      startedContinuation?.resume()
      startedContinuation = .none
    }
  }

  /// Waits until `send(_:)` begins or returns immediately when it already began.
  func waitUntilStarted() async {
    guard !hasStarted else { return }
    await withCheckedContinuation { startedContinuation = $0 }
  }

  /// Resumes the suspended request with a deterministic response.
  func resume(with response: HTTPTransportResponse) {
    responseContinuation?.resume(returning: response)
    responseContinuation = .none
  }
}

/// Scenario: cancellation during transport is propagated after response.
@Test func cancellationDuringTransportIsPropagatedAfterResponse() async throws {
  let transport = SuspendedHTTPTransport()
  let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
  let task = Task { try await client.searchMoviePage(title: "Alien", year: .none, page: 1) }
  await transport.waitUntilStarted()
  task.cancel()
  await transport.resume(with: response("{\"page\":1,\"total_pages\":0,\"results\":[]}"))
  await #expect(throws: CancellationError.self) { try await task.value }
}
