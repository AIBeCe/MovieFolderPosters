import Foundation
import HTTPTransport
@testable import TMDb
import Testing

/// Direct lookup captures language and rejects a response for another identity.
@Test func identifierLookupPreservesIdentityAndLanguage() async throws {
  let json = #"{"id":42,"title":"Alien","original_title":"Alien","release_date":"1979-05-25"}"#
  let transport = ScriptedHTTPTransport([.success(response(json))])
  let client = try TMDbClient(token: TMDbAccessToken("fixture"), transport: transport)
  #expect(try await client.movie(movieID: 42, language: TMDbLanguage("pt-BR"))?.id == 42)
  let request = try #require(await transport.capturedRequests().first)
  #expect(request.url?.path == "/3/movie/42")
  #expect(request.url?.query?.contains("language=pt-BR") == true)
}

/// Invalid identifiers never dispatch provider work.
@Test(arguments: [0, -1, Int(Int32.max) + 1])
func identifierLookupRejectsInvalidID(id: Int) async throws {
  let transport = ScriptedHTTPTransport([])
  let client = try TMDbClient(token: TMDbAccessToken("fixture"), transport: transport)
  await #expect(throws: TMDbError.invalidQuery) { try await client.movie(movieID: id, language: .english) }
  #expect(await transport.capturedRequests().isEmpty)
}

/// Malformed records cannot establish a movie identity.
@Test(arguments: [
  #"{"id":43,"title":"Alien","original_title":"Alien"}"#,
  #"{"id":42,"title":" ","original_title":"Alien"}"#,
  #"{"id":42,"title":"Alien","original_title":"Alien","release_date":"1979-02-30"}"#
]) func identifierLookupRejectsMalformedMovie(json: String) async throws {
  let client = try TMDbClient(token: TMDbAccessToken("fixture"),
    transport: ScriptedHTTPTransport([.success(response(json))]))
  await #expect(throws: TMDbError.malformedResponse) { try await client.movie(movieID: 42, language: .english) }
}

/// Mixed-media find results never leak television identities into movie matching.
@Test func identifierLookupIgnoresNonMovieResults() async throws {
  let transport = ScriptedHTTPTransport([.success(response(#"{"movie_results":[],"tv_results":[{"id":42}]}"#))])
  let client = try TMDbClient(token: TMDbAccessToken("fixture"), transport: transport)
  #expect(try await client.movie(imdbID: "tt0078748", language: .english) == .none)
}

/// Find resolves only one valid movie and forwards the external source and selected language.
@Test func identifierLookupResolvesIMDb() async throws {
  let json = #"{"movie_results":[{"id":42,"title":"Alien","original_title":"Alien"}]}"#
  let transport = ScriptedHTTPTransport([.success(response(json))])
  let client = try TMDbClient(token: TMDbAccessToken("fixture"), transport: transport)
  #expect(try await client.movie(imdbID: "tt0078748", language: .english)?.id == 42)
  let request = try #require(await transport.capturedRequests().first)
  #expect(request.url?.path == "/3/find/tt0078748")
  #expect(request.url?.query?.contains("external_source=imdb_id") == true)
}

/// Ambiguous or incomplete find bodies never establish uniqueness.
@Test(arguments: [#"{}"#, #"{"movie_results":[{},{}]}"#,
  #"{"movie_results":[{"id":42,"title":"A","original_title":"A"},{"id":43,"title":"A","original_title":"A"}]}"#])
func identifierLookupRejectsMalformedFind(json: String) async throws {
  let client = try TMDbClient(token: TMDbAccessToken("fixture"),
    transport: ScriptedHTTPTransport([.success(response(json))]))
  await #expect(throws: TMDbError.malformedResponse) {
    try await client.movie(imdbID: "tt0078748", language: .english)
  }
}

/// Unusable IMDb input cannot create a provider URL.
@Test(arguments: ["tt0000000", "tt123", "tt12345678901", "tt1234567/path", "TT0078748"])
func identifierLookupRejectsMalformedIMDb(id: String) async throws {
  let transport = ScriptedHTTPTransport([])
  let client = try TMDbClient(token: TMDbAccessToken("fixture"), transport: transport)
  await #expect(throws: TMDbError.invalidQuery) { try await client.movie(imdbID: id, language: .english) }
  #expect(await transport.capturedRequests().isEmpty)
}
