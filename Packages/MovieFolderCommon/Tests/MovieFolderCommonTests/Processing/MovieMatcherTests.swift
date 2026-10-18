import Network
import Testing

@testable import MovieFolderCommon

/// Regression coverage for exact movie identity matching and ambiguity rejection.
struct MovieMatcherTests {
  /// Verifies accepts Unique Title And Year Agreement.
  @Test func acceptsUniqueTitleAndYearAgreement() {
    let movie = candidate(1, "The Drama", 2026)
    #expect(MovieMatcher().match(title: "The Drama", year: 2026, search: results([movie])) == .matched(movie))
  }

  /// Verifies ignores Search Order And Rejects Wrong Years.
  @Test func ignoresSearchOrderAndRejectsWrongYears() {
    let wrong = candidate(2, "The Drama", 1995)
    let right = candidate(1, "The Drama", 2026)
    #expect(
      MovieMatcher().match(
        title: "The Drama", year: 2026,
        search: results([wrong, right])) == .matched(right))
  }

  /// Verifies identical Titles Without Year Remain Ambiguous.
  @Test func identicalTitlesWithoutYearRemainAmbiguous() {
    let search = results([candidate(1, "The Drama", 1995), candidate(2, "The Drama", 2026)])
    #expect(MovieMatcher().match(title: "The Drama", year: nil, search: search) == .unresolved(.ambiguous))
  }

  /// Verifies unrelated Search Results Stay Unresolved.
  @Test func unrelatedSearchResultsStayUnresolved() {
    let search = results([candidate(1, "Something Else", 2026)])
    #expect(MovieMatcher().match(title: "The Drama", year: 2026, search: search) == .unresolved(.noSuitableMatch))
  }

  /// Verifies normalizes Case Accents Punctuation And Whitespace.
  @Test func normalizesCaseAccentsPunctuationAndWhitespace() {
    let movie = candidate(1, "Amélie: The Movie", 2001)
    #expect(
      MovieMatcher().match(
        title: "  AMELIE-the   MOVIE ", year: 2001,
        search: results([movie])) == .matched(movie))
  }

  /// Verifies compares Original Title For International Movies.
  @Test func comparesOriginalTitleForInternationalMovies() {
    let movie = candidate(1, "Spirited Away", 2001, original: "千と千尋の神隠し")
    #expect(
      MovieMatcher().match(
        title: "千と千尋の神隠し", year: 2001,
        search: results([movie])) == .matched(movie))
  }

  /// Verifies title Similarity Does Not Override Conflict.
  @Test func titleSimilarityDoesNotOverrideConflict() {
    let search = results([candidate(1, "The Drama Returns", 2026)])
    #expect(MovieMatcher().match(title: "The Drama", year: 2026, search: search) == .unresolved(.noSuitableMatch))
  }

  /// Verifies title Numbers Remain Significant.
  @Test func titleNumbersRemainSignificant() {
    let search = results([candidate(1, "Blade Runner", 2017)])
    #expect(
      MovieMatcher().match(
        title: "Blade Runner 2049", year: 2017,
        search: search) == .unresolved(.noSuitableMatch))
  }

  /// Verifies unknown Candidate Year Cannot Satisfy Supplied Year.
  @Test func unknownCandidateYearCannotSatisfySuppliedYear() {
    let search = results([candidate(1, "The Drama", nil)])
    #expect(MovieMatcher().match(title: "The Drama", year: 2026, search: search) == .unresolved(.noSuitableMatch))
  }

  /// Verifies unknown Query Year Still Allows Unique Exact Title.
  @Test func unknownQueryYearStillAllowsUniqueExactTitle() {
    let movie = candidate(1, "The Drama", nil)
    #expect(MovieMatcher().match(title: "The Drama", year: nil, search: results([movie])) == .matched(movie))
  }

  /// Verifies different IDs With Same Title And Year Remain Ambiguous.
  @Test func differentIDsWithSameTitleAndYearRemainAmbiguous() {
    let search = results([candidate(1, "The Drama", 2026), candidate(2, "The Drama", 2026)])
    #expect(MovieMatcher().match(title: "The Drama", year: 2026, search: search) == .unresolved(.ambiguous))
  }

  /// Verifies poster Availability Cannot Resolve Identity Tie.
  @Test func posterAvailabilityCannotResolveIdentityTie() {
    let search = results([candidate(1, "The Drama", 2026), candidate(2, "The Drama", 2026, poster: nil)])
    #expect(MovieMatcher().match(title: "The Drama", year: 2026, search: search) == .unresolved(.ambiguous))
  }

  /// Verifies unique Movie Without Poster Remains Unresolved.
  ///
  /// - Parameter poster: The optional source poster path supplied by a matching test.
  @Test(arguments: [nil, "", "  "] as [String?])
  func uniqueMovieWithoutPosterRemainsUnresolved(_ poster: String?) {
    let search = results([candidate(1, "The Drama", 2026, poster: poster)])
    #expect(MovieMatcher().match(title: "The Drama", year: 2026, search: search) == .unresolved(.missingPoster))
  }

  /// Verifies ignores Identical Duplicate Records.
  @Test func ignoresIdenticalDuplicateRecords() {
    let movie = candidate(1, "The Drama", 2026)
    #expect(
      MovieMatcher().match(
        title: "The Drama", year: 2026,
        search: results([movie, movie])) == .matched(movie))
  }

  /// Verifies conflicting Records For Selected IDRemain Ambiguous.
  @Test func conflictingRecordsForSelectedIDRemainAmbiguous() {
    let search = results([candidate(1, "The Drama", 2026), candidate(1, "The Drama", 1995)])
    #expect(MovieMatcher().match(title: "The Drama", year: 2026, search: search) == .unresolved(.ambiguous))
  }

  /// Verifies incomplete Search Cannot Establish Unique Match.
  @Test func incompleteSearchCannotEstablishUniqueMatch() {
    let search = results([candidate(1, "The Drama", 2026)], hasMorePages: true)
    #expect(MovieMatcher().match(title: "The Drama", year: 2026, search: search) == .unresolved(.incompleteSearch))
  }

  /// Verifies empty Search Remains Unresolved.
  @Test func emptySearchRemainsUnresolved() {
    #expect(
      MovieMatcher().match(
        title: "The Drama", year: 2026,
        search: results([])) == .unresolved(.noSuitableMatch))
  }

  /// Verifies rejects Title Without Letters Or Numbers.
  ///
  /// - Parameter title: The movie title used for search or exact normalized comparison.
  @Test(arguments: ["", "   ", "---"])
  func rejectsTitleWithoutLettersOrNumbers(_ title: String) {
    #expect(MovieMatcher().match(title: title, year: nil, search: results([])) == .unresolved(.invalidQuery))
  }

  /// Verifies rejects Unsupported Years.
  ///
  /// - Parameter year: The release year when available; no value preserves year uncertainty.
  @Test(arguments: [0, 1887, 2100])
  func rejectsUnsupportedYears(_ year: Int) {
    #expect(
      MovieMatcher().match(
        title: "The Drama", year: year,
        search: results([])) == .unresolved(.invalidQuery))
  }

  /// Builds a movie record whose fields vary explicitly across matching tests.
  ///
  /// - Parameters:
  ///   - id: Stable identity of the represented collection or movie record.
  ///   - title: The movie title used for search or exact normalized comparison.
  ///   - year: The release year when available; no value preserves year uncertainty.
  ///   - original: The original-language title used to test title normalization.
  ///   - poster: The optional source poster path supplied by a matching test.
  /// - Returns: The constructed MovieMetadata result.
  private func candidate(
    _ id: Int, _ title: String, _ year: Int?, original: String? = nil,
    poster: String? = "/poster.jpg"
  ) -> MovieMetadata {
    MovieMetadata(id: id, title: title, originalTitle: original ?? title, releaseYear: year, posterPath: poster)
  }

  /// Builds a search response with explicit pagination completeness.
  ///
  /// - Parameters:
  ///   - movies: Movie records retained from the cached response.
  ///   - hasMorePages: Whether unexamined search pages prevent a unique automatic match.
  /// - Returns: The constructed MovieSearchResult result.
  private func results(_ movies: [MovieMetadata], hasMorePages: Bool = false) -> MovieSearchResult {
    MovieSearchResult(movies: movies, hasMorePages: hasMorePages)
  }
}
