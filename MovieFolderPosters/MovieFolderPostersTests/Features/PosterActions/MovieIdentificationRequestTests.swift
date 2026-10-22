import Testing

@testable import MovieFolderPosters

/// Verifies the identification values shared by the preview and explicit search.
struct MovieIdentificationRequestTests {
  /// Catches previewing untrimmed fields or disclosing an empty year as a value.
  @Test func normalizesOnlyTheFieldsSentBySearch() throws {
    let request = try MovieIdentificationRequest(title: "  Alien  ", yearText: " 1979 ")
    #expect(request.title == "Alien")
    #expect(request.year == 1979)
    #expect(try MovieIdentificationRequest(title: "Alien", yearText: " ").year == .none)
  }

  /// Catches invalid fields appearing as a sendable preview.
  @Test(arguments: ["1800", "2100", "year", "1979.0"])
  func invalidYearsCannotFormARequest(year: String) {
    #expect(throws: MovieIdentificationRequest.InputError.invalidYear) {
      try MovieIdentificationRequest(title: "Alien", yearText: year)
    }
  }

  /// Catches accepting an empty title or a header-like multiline title.
  @Test func invalidTitlesCannotFormARequest() {
    #expect(throws: MovieIdentificationRequest.InputError.missingTitle) {
      try MovieIdentificationRequest(title: " ", yearText: "")
    }
    #expect(throws: MovieIdentificationRequest.InputError.invalidTitle) {
      try MovieIdentificationRequest(title: "Alien\nPrivate", yearText: "")
    }
  }
}
