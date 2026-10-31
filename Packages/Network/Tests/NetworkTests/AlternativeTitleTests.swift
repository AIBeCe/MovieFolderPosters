import Foundation
@testable import Network
import Testing

/// Provider evidence preserves provenance and uses the authenticated movie endpoint.
@Test func alternativeTitlesPreserveProviderEvidence() async throws {
  let transport = ScriptedHTTPTransport([.success(response(
    "{\"id\":42,\"titles\":[{\"iso_3166_1\":\"BR\",\"title\":\"O Oitavo Passageiro\",\"type\":\"\"}]}"))])
  let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
  let titles = try await client.alternativeTitles(movieID: 42)
  #expect(titles[42]?.first?.countryCode == "BR")
  #expect(titles[42]?.first?.title == "O Oitavo Passageiro")
  let request = try #require(await transport.capturedRequests().first)
  #expect(request.url?.path == "/3/movie/42/alternative_titles")
  #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
}

/// An empty completed response is distinct from malformed or mismatched evidence.
@Test(arguments: ["{\"id\":43,\"titles\":[]}", "{\"id\":42}",
  "{\"id\":42,\"titles\":[{\"iso_3166_1\":\"US\",\"title\":\" \" ,\"type\":\"\"}]}"])
func alternativeTitlesRejectMalformedEvidence(json: String) async throws {
  let transport = ScriptedHTTPTransport([.success(response(json))])
  let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
  await #expect(throws: TMDbError.malformedResponse) { try await client.alternativeTitles(movieID: 42) }
}

/// Language parsing is canonical, strict, and survives a string Codable round trip.
@Test func languageValidationAndRoundTrip() throws {
  let language = try TMDbLanguage("PT-br")
  #expect(language.rawValue == "pt-BR")
  #expect(try JSONDecoder().decode(TMDbLanguage.self, from: JSONEncoder().encode(language)) == language)
  for invalid in ["", " en-US", "en_US", "en-Latn", "zz", "en-ZZ", "en-US-extra"] {
    #expect(throws: TMDbError.invalidQuery) { try TMDbLanguage(invalid) }
  }
}

/// Successful empty evidence remains completed and records the new closed category.
@Test func alternativeTitlesEmptyEvidenceAndCategory() async throws {
  let delegate = TMDbRequestObservationRecorderDelegate()
  let transport = ScriptedHTTPTransport([.success(response("{\"id\":42,\"titles\":[]}"))])
  let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport, requestDelegate: delegate)
  #expect(try await client.alternativeTitles(movieID: 42) == [42: []])
  let observed = await delegate.captured()
  #expect(observed.prepared == [.alternativeTitles])
  #expect(observed.completed.first?.0 == .alternativeTitles)
  #expect(TMDbRequestCategory.movieSearch.rawValue == "movieSearch")
  #expect(TMDbRequestCategory.credentialValidation.rawValue == "credentialValidation")
  #expect(TMDbRequestCategory.posterConfiguration.rawValue == "posterConfiguration")
  #expect(TMDbRequestCategory.posterDownload.rawValue == "posterDownload")
}

/// Invalid identities are rejected without dispatching a network request.
@Test(arguments: [0, -42])
func alternativeTitlesRejectInvalidID(id: Int) async throws {
  let transport = ScriptedHTTPTransport([])
  let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
  await #expect(throws: TMDbError.invalidQuery) { try await client.alternativeTitles(movieID: id) }
  #expect(await transport.capturedRequests().isEmpty)
}

/// A plausible JSON body cannot override absent or incorrect response media types.
@Test(arguments: [nil, "text/plain", "application/jsonp"] as [String?])
func alternativeTitlesRequireJSONContentType(contentType: String?) async throws {
  let transport = ScriptedHTTPTransport([.success(HTTPTransportResponse(data: Data("{\"id\":42,\"titles\":[]}".utf8),
    statusCode: 200, contentType: contentType))])
  let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
  await #expect(throws: TMDbError.malformedResponse) { try await client.alternativeTitles(movieID: 42) }
}

/// Authentication and provider backoff retain the existing safe typed contract on the alias endpoint.
@Test(arguments: [401, 403, 429])
func alternativeTitlesRetainProviderFailures(status: Int) async throws {
  let transport = ScriptedHTTPTransport([.success(HTTPTransportResponse(data: Data(), statusCode: status,
    contentType: "text/plain", retryAfter: "30"))])
  let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
  let expected: TMDbError = status == 429 ? .rateLimited(retryAfter: "30") : .authentication
  await #expect(throws: expected) { try await client.alternativeTitles(movieID: 42) }
}

/// Cancellation during an alias request discards returned evidence and records cancellation once.
@Test func alternativeTitlesCancellationAfterDispatch() async throws {
  let transport = SuspendedHTTPTransport()
  let delegate = TMDbRequestObservationRecorderDelegate()
  let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport, requestDelegate: delegate)
  let task = Task { try await client.alternativeTitles(movieID: 42) }
  await transport.waitUntilStarted()
  task.cancel()
  await transport.resume(with: response("{\"id\":42,\"titles\":[]}"))
  await #expect(throws: CancellationError.self) { try await task.value }
  let observed = await delegate.captured()
  #expect(observed.completed.count == 1)
  #expect(observed.completed.first?.1 == .cancelled)
}

/// Selected regional language reaches the actual provider request, without translating its query.
@Test func searchForwardsSelectedLanguage() async throws {
  let transport = ScriptedHTTPTransport([.success(response("{\"page\":1,\"total_pages\":0,\"results\":[]}"))])
  let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
  _ = try await client.searchMovies(title: "Alien", year: 1979, language: TMDbLanguage("pt-BR"))
  let url = try #require(await transport.capturedRequests().first?.url)
  let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
  #expect(query.first(where: { $0.name == "language" })?.value == "pt-BR")
  #expect(query.first(where: { $0.name == "query" })?.value == "Alien")
}
