import Foundation
import Testing

@testable import Network

/// Checks the credential validation endpoint, response handling, and cancellation behavior.
struct CredentialValidationTests {
  /// Sends the token only as a bearer header to the TMDb authentication endpoint.
  @Test func sendsAuthenticatedAuthenticationRequest() async throws {
    let transport = ScriptedHTTPTransport([
      .success(HTTPTransportResponse(
        data: Data("{\"success\":true}".utf8), statusCode: 200,
        contentType: "Application/JSON; charset=utf-8"))
    ])
    let client = try TMDbClient(token: TMDbAccessToken("credential-secret"), transport: transport)

    try await client.validateCredential()

    let requests = await transport.capturedRequests()
    let request = try #require(requests.first)
    let url = try #require(request.url)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(requests.count == 1)
    #expect(request.httpMethod == "GET")
    #expect(components.scheme == "https")
    #expect(components.host == "api.themoviedb.org")
    #expect(components.path == "/3/authentication")
    #expect(components.queryItems == .none || components.queryItems?.isEmpty == true)
    #expect(request.httpBody == .none)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer credential-secret")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
  }

  /// Rejects malformed or untrusted response bodies without exposing their contents.
  @Test(arguments: [
    ("not-json", "application/json"),
    ("{}", "application/json"),
    ("{\"success\":false,\"message\":\"private response\"}", "application/json"),
    ("{\"success\":\"true\"}", "application/json"),
    ("{\"success\":true}", "text/plain")
  ])
  func rejectsMalformedOrUntrustedResponses(json: String, contentType: String) async throws {
    let transport = ScriptedHTTPTransport([
      .success(HTTPTransportResponse(data: Data(json.utf8), statusCode: 200, contentType: contentType))
    ])
    let client = try TMDbClient(token: TMDbAccessToken("credential-secret"), transport: transport)

    do {
      try await client.validateCredential()
      Issue.record("Expected credential validation to reject the response")
    } catch let error as TMDbError {
      #expect(error == .malformedResponse)
      #expect(!String(describing: error).contains("credential-secret"))
      #expect(!String(describing: error).contains("private response"))
    }
  }

  /// Maps provider authentication responses to the existing typed error.
  @Test(arguments: [401, 403])
  func mapsAuthenticationStatus(status: Int) async throws {
    let transport = ScriptedHTTPTransport([
      .success(HTTPTransportResponse(data: Data("private body".utf8), statusCode: status, contentType: "text/plain"))
    ])
    let client = try TMDbClient(token: TMDbAccessToken("credential-secret"), transport: transport)

    await #expect(throws: TMDbError.authentication) { try await client.validateCredential() }
  }

  /// Preserves provider retry metadata when the endpoint is rate limited.
  @Test func preservesRateLimitRetryAfter() async throws {
    let transport = ScriptedHTTPTransport([
      .success(HTTPTransportResponse(data: Data("private body".utf8), statusCode: 429,
        contentType: "text/plain", retryAfter: "45"))
    ])
    let client = try TMDbClient(token: TMDbAccessToken("credential-secret"), transport: transport)

    await #expect(throws: TMDbError.rateLimited(retryAfter: "45")) {
      try await client.validateCredential()
    }
  }

  /// Rejects unexpected success and server statuses through the common status boundary.
  @Test(arguments: [204, 500, 503])
  func rejectsUnexpectedStatus(status: Int) async throws {
    let transport = ScriptedHTTPTransport([.success(response("{\"success\":true}", status: status))])
    let client = try TMDbClient(token: TMDbAccessToken("credential-secret"), transport: transport)

    await #expect(throws: TMDbError.httpStatus(status)) { try await client.validateCredential() }
  }

  /// Keeps offline failures typed without exposing the credential.
  @Test func handlesOfflineFailureWithoutLeakingToken() async throws {
    let transport = ScriptedHTTPTransport([.failure(URLError(.notConnectedToInternet))])
    let client = try TMDbClient(token: TMDbAccessToken("credential-secret"), transport: transport)

    await #expect(throws: TMDbError.transport(code: URLError.notConnectedToInternet.rawValue)) {
      try await client.validateCredential()
    }
  }

  /// Applies the shared response-size limit to authentication responses.
  @Test func rejectsOversizedResponse() async throws {
    let oversized = Data(repeating: 0x61, count: 10 * 1_024 * 1_024 + 1)
    let transport = ScriptedHTTPTransport([
      .success(HTTPTransportResponse(data: oversized, statusCode: 200, contentType: "application/json"))
    ])
    let client = try TMDbClient(token: TMDbAccessToken("credential-secret"), transport: transport)

    await #expect(throws: TMDbError.responseTooLarge) { try await client.validateCredential() }
  }

  /// Observes cancellation before sending any request.
  @Test func honorsCancellationBeforeSending() async throws {
    let transport = ScriptedHTTPTransport([])
    let client = try TMDbClient(token: TMDbAccessToken("credential-secret"), transport: transport)
    let task = Task { @Sendable in
      withUnsafeCurrentTask { $0?.cancel() }

      try await client.validateCredential()
    }

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await transport.capturedRequests().isEmpty)
  }

  /// Observes cancellation while the credential request is suspended in its transport.
  @Test func honorsCancellationDuringTransport() async throws {
    let transport = SuspendedHTTPTransport()
    let client = try TMDbClient(token: TMDbAccessToken("credential-secret"), transport: transport)
    let task = Task { try await client.validateCredential() }
    await transport.waitUntilStarted()
    task.cancel()
    await transport.resume(with: response("{\"success\":true}"))

    await #expect(throws: CancellationError.self) { try await task.value }
  }
}
