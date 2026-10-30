import Foundation
@testable import Network
import Testing

/// The movie endpoint retains complete dated provenance and UTC Gregorian year projections.
@Test func releaseDatesPreserveDatedEvidence() async throws {
  let json = """
    {"id":42,"results":[{"iso_3166_1":"US","release_dates":[
      {"release_date":"1979-05-25T00:00:00.000Z","type":1},
      {"release_date":"1980-01-01T00:00:00.000Z","type":3},
      {"release_date":"1981-01-01T00:00:00.000Z","type":99}]}]}
    """
  let transport = ScriptedTransport([.success(response(json))])
  let delegate = RecordingRequestDelegate()
  let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport, requestDelegate: delegate)
  let dates = try #require(try await client.releaseDates(movieID: 42)[42])
  #expect(dates.map(\.movieYear) == [MovieYear(year: 1979, type: .premiere),
    MovieYear(year: 1980, type: .theatrical), nil])
  #expect(dates.first?.timestamp == "1979-05-25T00:00:00.000Z")
  #expect(dates.first?.countryCode == "US")
  #expect(dates.last?.type == 99)
  #expect(try JSONDecoder().decode([MovieReleaseDate].self, from: JSONEncoder().encode(dates)) == dates)
  let request = try #require(await transport.capturedRequests().first)
  #expect(request.url?.path == "/3/movie/42/release_dates")
  #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
  #expect(await delegate.captured().prepared == [.releaseDates])
}

/// Empty success remains keyed; wrong IDs and structurally incomplete evidence fail closed.
@Test(arguments: ["{\"id\":43,\"results\":[]}", "{\"id\":42}",
  "{\"id\":42,\"results\":[{\"iso_3166_1\":\"US\"}]}"])
func releaseDatesRejectIncompleteResponse(json: String) async throws {
  let transport = ScriptedTransport([.success(response(json))])
  let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
  await #expect(throws: TMDbError.malformedResponse) { try await client.releaseDates(movieID: 42) }
}

/// Calendar rollovers, invalid countries, nonpositive types, and unparseable timestamps never become year evidence.
@Test(arguments: ["1979-02-29T00:00:00.000Z", "1980-13-01T00:00:00.000Z", "1980-01-01",
  "1980-01-01T24:00:00.000Z", "1980-01-01T00:00:00.000Zjunk"])
func releaseDatesRejectInvalidTimestamp(timestamp: String) throws {
  #expect(throws: TMDbError.malformedResponse) {
    try MovieReleaseDate(countryCode: "US", timestamp: timestamp, type: 3)
  }
}

/// Valid completed empty evidence does not become a missing response.
@Test func releaseDatesEmptyResponse() async throws {
  let transport = ScriptedTransport([.success(response("{\"id\":42,\"results\":[]}"))])
  let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
  #expect(try await client.releaseDates(movieID: 42) == [42: []])
}

/// Only well-formed country and event-type provenance enters the public model.
@Test(arguments: [("us", 1), ("U", 1), ("USA", 1), (" US", 1), ("US", 0), ("US", -1), ("ZZ", 1)])
func releaseDatesRejectInvalidProvenance(country: String, type: Int) throws {
  #expect(throws: TMDbError.malformedResponse) {
    try MovieReleaseDate(countryCode: country, timestamp: "1980-01-01T00:00:00Z", type: type)
  }
}

/// A machine's local timezone cannot change the source year projected from the validated instant.
@Test func releaseDatesUseGregorianUTCYear() throws {
  let event = try MovieReleaseDate(countryCode: "US", timestamp: "1980-01-01T00:30:00+01:00", type: 2)
  #expect(event.movieYear == MovieYear(year: 1979, type: .limitedTheatrical))
}

/// Incorrect media types cannot turn a plausible body into completed release evidence.
@Test(arguments: [nil, "text/plain", "application/jsonp"] as [String?])
func releaseDatesRequireJSON(contentType: String?) async throws {
  let transport = ScriptedTransport([.success(HTTPResponse(data: Data("{\"id\":42,\"results\":[]}".utf8),
    statusCode: 200, contentType: contentType))])
  let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
  await #expect(throws: TMDbError.malformedResponse) { try await client.releaseDates(movieID: 42) }
}

/// The date endpoint uses the existing typed authentication and throttling contract.
@Test(arguments: [401, 403, 429])
func releaseDatesRetainProviderFailure(status: Int) async throws {
  let transport = ScriptedTransport([.success(HTTPResponse(data: Data(), statusCode: status,
    contentType: "text/plain", retryAfter: "30"))])
  let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
  let expected: TMDbError = status == 429 ? .rateLimited(retryAfter: "30") : .authentication
  await #expect(throws: expected) { try await client.releaseDates(movieID: 42) }
}

/// Invalid identities never dispatch authenticated requests.
@Test(arguments: [0, -42])
func releaseDatesRejectInvalidMovieID(id: Int) async throws {
  let transport = ScriptedTransport([])
  let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
  await #expect(throws: TMDbError.invalidQuery) { try await client.releaseDates(movieID: id) }
  #expect(await transport.capturedRequests().isEmpty)
}

/// Cancellation after dispatch cannot publish otherwise valid release events.
@Test func releaseDatesCancellationAfterDispatch() async throws {
  let transport = BlockingTransport()
  let delegate = RecordingRequestDelegate()
  let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport, requestDelegate: delegate)
  let task = Task { try await client.releaseDates(movieID: 42) }
  await transport.waitUntilStarted()
  task.cancel()
  await transport.resume(with: response("{\"id\":42,\"results\":[]}"))
  await #expect(throws: CancellationError.self) { try await task.value }
  let observed = await delegate.captured()
  #expect(observed.completed.count == 1)
  #expect(observed.completed.first?.1 == .cancelled)
}
