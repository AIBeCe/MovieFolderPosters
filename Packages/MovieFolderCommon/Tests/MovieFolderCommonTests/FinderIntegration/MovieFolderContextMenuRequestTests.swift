import Foundation
@testable import MovieFolderCommon
import Testing

/// Validates bounded read-only Finder presentation routes.
struct MovieFolderContextMenuRequestTests {
  /// Preserves root and child evidence while rejecting collection Copy requests.
  @Test func roundTripsCollectionAndChild() throws {
    let root = UUID()
    for action in MovieFolderContextMenuAction.allCases {
      let request = try MovieFolderContextMenuRequest(rootID: root,
        target: .child(name: "Movie & Name", identity: "1:2"), action: action)
      #expect(try MovieFolderContextMenuRequest(url: request.makeURL()) == request)
    }
    let collection = try MovieFolderContextMenuRequest(rootID: root, target: .collection, action: .inspect)
    #expect(try MovieFolderContextMenuRequest(url: collection.makeURL()) == collection)
    #expect(throws: MovieFolderContextMenuRequestError.self) {
      try MovieFolderContextMenuRequest(rootID: root, target: .collection, action: .copyMovieTitle)
    }
  }

  /// Rejects invalid names and unexpected, duplicate, or incomplete URL fields.
  @Test func rejectsMalformedEvidenceAndRoutes() throws {
    let root = UUID()
    for child in ["", ".hidden", "..", "A/B", "A\\B", "A\nB", String(repeating: "a", count: 256)] {
      #expect(throws: MovieFolderContextMenuRequestError.self) {
        try MovieFolderContextMenuRequest(rootID: root, target: .child(name: child, identity: "id"), action: .inspect)
      }
    }
    for suffix in ["&root=other", "&extra=yes", "&child=Movie", "&identity=id", "#fragment"] {
      let url = try #require(URL(string: "moviefolderposters://results?root=\(root)&action=inspect" + suffix))
      #expect(throws: MovieFolderContextMenuRequestError.self) { try MovieFolderContextMenuRequest(url: url) }
    }
  }
}
