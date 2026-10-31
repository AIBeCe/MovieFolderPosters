import Foundation
@testable import MovieFolderCommon
import Testing

/// Covers typed Finder inclusion routes without launching the host.
struct MovieFolderInclusionRequestTests {
  /// File URLs and revision evidence survive a route round trip.
  @Test func roundTripPreservesCapturedEvidence() throws {
    let request = MovieFolderInclusionRequest(action: .exclude, collectionID: UUID(),
      folderURL: URL(fileURLWithPath: "/Movies/A Movie (2026)"), folderIdentity: "volume:folder",
      expectedProcessingConfigurationRevision: UUID())
    #expect(try MovieFolderInclusionRequest(url: request.url) == request)
  }

  /// Old Finder links remain readable while newly encoded links use the inclusion route.
  @Test func legacyRouteDecodesToCanonicalInclusionRoute() throws {
    let request = MovieFolderInclusionRequest(action: .exclude, collectionID: UUID(),
      folderURL: URL(fileURLWithPath: "/Movies/A Movie"), folderIdentity: "volume:folder",
      expectedProcessingConfigurationRevision: UUID())
    let oldRoute = try #require(URL(string: request.url.absoluteString.replacingOccurrences(
      of: "/inclusion?", with: "/participation?")))

    #expect(try MovieFolderInclusionRequest(url: oldRoute) == request)
  }

  /// Duplicate fields, foreign routes, and remote folders cannot enter the host flow.
  @Test func rejectsUnsupportedRoutes() throws {
    let request = MovieFolderInclusionRequest(action: .include, collectionID: UUID(),
      folderURL: URL(fileURLWithPath: "/Movies/Movie"), folderIdentity: "folder",
      expectedProcessingConfigurationRevision: UUID())
    let duplicate = try #require(URL(string: request.url.absoluteString + "&identity=other"))
    #expect(throws: MoviePosterRequestError.self) { try MovieFolderInclusionRequest(url: duplicate) }
    let foreign = try #require(URL(string: "https://example.com/inclusion"))
    #expect(throws: MoviePosterRequestError.self) { try MovieFolderInclusionRequest(url: foreign) }
  }
}
