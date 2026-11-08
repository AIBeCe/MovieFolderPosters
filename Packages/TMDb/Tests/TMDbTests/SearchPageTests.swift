import Foundation
import Testing

import HTTPTransport
@testable import TMDb

/// Verifies that the client dispatches exactly the requested page.
@Test func searchPageForwardsRequestedPage() async throws {
  let transport = ScriptedHTTPTransport([.success(response("{\"page\":3,\"total_pages\":5,\"results\":[]}"))])
  let client = try TMDbClient(token: TMDbAccessToken("fixture"), transport: transport)
  let result = try await client.searchMoviePage(title: "Movie", year: .none, language: .english, page: 3)
  #expect(result.page == 3)
  #expect(result.totalPages == 5)
  let requests = await transport.capturedRequests()
  #expect(requests.count == 1)
  #expect(requests.first?.url?.query?.contains("page=3") == true)
}

/// Rejects impossible page metadata instead of silently treating it as completion.
@Test(arguments: ["{\"page\":2,\"total_pages\":1,\"results\":[]}",
                  "{\"page\":2,\"total_pages\":0,\"results\":[]}"])
func searchPageRejectsImpossibleTotals(json: String) async throws {
  let transport = ScriptedHTTPTransport([.success(response(json))])
  let client = try TMDbClient(token: TMDbAccessToken("fixture"), transport: transport)
  await #expect(throws: TMDbError.malformedResponse) {
    try await client.searchMoviePage(title: "Movie", year: .none, language: .english, page: 2)
  }
}

/// Invalid page requests fail before the transport can observe a request.
@Test(arguments: [0, -1]) func searchPageRejectsNonpositiveRequest(page: Int) async throws {
  let transport = ScriptedHTTPTransport([])
  let client = try TMDbClient(token: TMDbAccessToken("fixture"), transport: transport)
  await #expect(throws: TMDbError.invalidQuery) {
    try await client.searchMoviePage(title: "Movie", year: .none, language: .english, page: page)
  }
  #expect(await transport.capturedRequests().isEmpty)
}
