import Testing

@testable import MovieFolderPosters

/// Verifies the matching values shared by the preview and explicit search.
struct MovieMatchingRequestTests {
  /// Catches previewing untrimmed fields or disclosing an empty year as a value.
  @Test func normalizesOnlyTheFieldsSentBySearch() throws {
    let request = try MovieMatchingRequest(title: "  Alien  ", yearText: " 1979 ")
    #expect(request.title == "Alien")
    #expect(request.year == 1979)
    #expect(try MovieMatchingRequest(title: "Alien", yearText: " ").year == .none)
  }

  /// Catches invalid fields appearing as a sendable preview.
  @Test(arguments: ["1800", "2100", "year", "1979.0"])
  func invalidYearsCannotFormARequest(year: String) {
    #expect(throws: MovieMatchingRequest.InputError.invalidYear) {
      try MovieMatchingRequest(title: "Alien", yearText: year)
    }
  }

  /// Catches accepting an empty title or a header-like multiline title.
  @Test func invalidTitlesCannotFormARequest() {
    #expect(throws: MovieMatchingRequest.InputError.missingTitle) {
      try MovieMatchingRequest(title: " ", yearText: "")
    }
    #expect(throws: MovieMatchingRequest.InputError.invalidTitle) {
      try MovieMatchingRequest(title: "Alien\nPrivate", yearText: "")
    }
  }
}
