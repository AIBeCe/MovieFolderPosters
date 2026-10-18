import Testing

@testable import MovieFolderCommon

/// Regression coverage for conservative release-name parsing.
struct ReleaseNameParserTests {
  /// Verifies extracts Title And Year.
  @Test func extractsTitleAndYear() {
    let expected = ParsedReleaseName(title: "The Drama", year: 2026)
    #expect(ReleaseNameParser().parse("The.Drama.2026") == .parsed(expected))
  }

  /// Verifies preserves Title Without Year.
  @Test func preservesTitleWithoutYear() {
    let expected = ParsedReleaseName(title: "Ride The Eagle", year: nil)
    #expect(ReleaseNameParser().parse("Ride.The.Eagle") == .parsed(expected))
  }

  /// Verifies normalizes Separators And Whitespace.
  @Test func normalizesSeparatorsAndWhitespace() {
    let expected = ParsedReleaseName(title: "North Star", year: 2023)
    #expect(ReleaseNameParser().parse("  North_Star  2023  ") == .parsed(expected))
  }

  /// Verifies rejects Empty Name.
  @Test func rejectsEmptyName() { #expect(ReleaseNameParser().parse("   ") == .unresolved(.emptyName)) }

  @Test(arguments: [
    ReleaseFixture("The.Drama.2026.2160p.WEB-DL.DDP5.1.Atmos.H265-GROUP", "The Drama", 2026),
    ReleaseFixture("North.Star.2023.1080p.BluRay.x264-GROUP", "North Star", 2023),
    ReleaseFixture("Ride.The.Eagle.2021.1080p.WEB-DL-GROUP", "Ride The Eagle", 2021),
    ReleaseFixture("Spider-Man.No.Way.Home.2021.2160p.BluRay.x265-GROUP", "Spider-Man No Way Home", 2021),
    ReleaseFixture(
      "Whisper.Of.The.Heart.1995.NORDiC.1080p.WEB-DL.H.264.DDP5.1-NoTrace",
      "Whisper Of The Heart", 1995),
    ReleaseFixture("The.Drama.2026.REMASTERED.2160p.WEB-DL", "The Drama", 2026),
    ReleaseFixture("North.Star.WEB-DL.x264-GROUP", "North Star", nil),
    ReleaseFixture("Ride.The.Eagle.1080p.WEB-DL-GROUP", "Ride The Eagle", nil),
    ReleaseFixture("Movie.2020.x265-GROUP", "Movie", 2020),
    ReleaseFixture("Movie.[2020].HDR10+.HEVC.DDP5.1-GROUP", "Movie", 2020),
    ReleaseFixture(
      "When Marnie Was There [2014] 1080p BDRip x265 DTS-HD MA 5.0 Kira [SEV]",
      "When Marnie Was There", 2014),
    ReleaseFixture(
      "Batman Knightfall Part 1 2026 2160p UHD BluRay REMUX DV HDR HEVC DTS-HD MA 5.1-d3g",
      "Batman Knightfall Part 1", 2026)
  ])
  /// Checks that release annotations are removed without losing the movie title or year.
  ///
  /// - Parameter fixture: The input and expected outcome for this parameterized regression.
  func extractsFullReleaseNames(_ fixture: ReleaseFixture) {
    #expect(
      ReleaseNameParser().parse(fixture.name)
        == .parsed(
          ParsedReleaseName(
            title: fixture.title,
            year: fixture.year)))
  }

  @Test(arguments: [
    ReleaseFixture("1917.2019.1080p.BluRay", "1917", 2019),
    ReleaseFixture("2001.A.Space.Odyssey.1968.1080p.BluRay", "2001 A Space Odyssey", 1968),
    ReleaseFixture("Blade.Runner.2049.[2017].2160p.WEB-DL", "Blade Runner 2049", 2017),
    ReleaseFixture("Summer.of.1984.(2000).1080p.WEB-DL", "Summer of 1984", 2000),
    ReleaseFixture("Remux.2023", "Remux", 2023),
    ReleaseFixture("The.Remux.Movie.2020.1080p.BluRay", "The Remux Movie", 2020),
    ReleaseFixture("The.Web.of.Life.2018", "The Web of Life", 2018),
    ReleaseFixture("The.Dolby.Vision.2020", "The Dolby Vision", 2020),
    ReleaseFixture("The.H265.Movie.2020", "The H265 Movie", 2020),
    ReleaseFixture("The.4K.Movie.2020", "The 4K Movie", 2020),
    ReleaseFixture("The.1080p.Movie", "The 1080p Movie", nil),
    ReleaseFixture("The.1984.Experiment", "The 1984 Experiment", nil),
    ReleaseFixture("1984", "1984", nil),
    ReleaseFixture("Movie.BluRay", "Movie BluRay", nil),
    ReleaseFixture("Amélie.(2001).1080p.BluRay", "Amélie", 2001),
    ReleaseFixture("Schindler's.List.1993.1080p.BluRay", "Schindler's List", 1993)
  ])
  /// Checks that technical-looking tokens remain when they belong to the movie title.
  ///
  /// - Parameter fixture: The input and expected outcome for this parameterized regression.
  func preservesLegitimateTitleTokens(_ fixture: ReleaseFixture) {
    #expect(
      ReleaseNameParser().parse(fixture.name)
        == .parsed(
          ParsedReleaseName(
            title: fixture.title,
            year: fixture.year)))
  }

  @Test(arguments: [
    UnresolvedFixture("Movie.1999.2000", .ambiguousYear),
    UnresolvedFixture("Movie.1999.2000.1080p.WEB-DL", .ambiguousYear),
    UnresolvedFixture("Blade.Runner.2049.2017.2160p.WEB-DL", .ambiguousYear),
    UnresolvedFixture("Movie.[1999].(2000).1080p.WEB-DL", .ambiguousYear),
    UnresolvedFixture("Movie.2020.Special.Edit.1080p", .ambiguousMetadata),
    UnresolvedFixture("1080p.WEB-DL.x265-GROUP", .missingTitle),
    UnresolvedFixture("[2020].1080p.WEB-DL", .missingTitle),
    UnresolvedFixture("(2020).1080p.BluRay", .missingTitle),
    UnresolvedFixture("Movie.[1999].1080p.(2000).WEB-DL", .ambiguousYear),
    UnresolvedFixture("Summer.of.1984.Remastered.[2000].1080p.WEB-DL", .ambiguousMetadata),
    UnresolvedFixture("The.BluRay.Remux.Movie.2020.1080p.WEB-DL", .ambiguousMetadata),
    UnresolvedFixture("The.4K.Vision.2020.1080p.WEB-DL", .ambiguousMetadata),
    UnresolvedFixture("The.Drama.2026...GROUP", .truncatedName),
    UnresolvedFixture("The.Drama…GROUP", .truncatedName),
    UnresolvedFixture("/Users/me/Movies", .invalidName)
  ])
  /// Checks that uncertain release evidence remains explicitly unresolved.
  ///
  /// - Parameter fixture: The input and expected outcome for this parameterized regression.
  func reportsUncertainNames(_ fixture: UnresolvedFixture) {
    #expect(ReleaseNameParser().parse(fixture.name) == .unresolved(fixture.issue))
  }
}

/// A release folder name and the title/year interpretation expected by a parameterized test.
struct ReleaseFixture: Sendable {
  /// The release folder name used as input to the parser fixture.
  let name: String
  /// The display or parsed movie title used by the matching workflow.
  let title: String
  /// The supported release year when confidently supplied by the folder name.
  let year: Int?

  /// Creates the release fixture from the supplied dependencies and state.
  ///
  /// - Parameters:
  ///   - name: The immediate child folder name.
  ///   - title: The movie title used for search or exact normalized comparison.
  ///   - year: The release year when available; no value preserves year uncertainty.
  init(_ name: String, _ title: String, _ year: Int?) {
    self.name = name
    self.title = title
    self.year = year
  }
}

/// A release folder name and the specific uncertainty expected by a parameterized test.
struct UnresolvedFixture: Sendable {
  /// The release folder name used as input to the parser fixture.
  let name: String
  /// The unresolved parsing reason expected for this fixture.
  let issue: ReleaseNameIssue

  /// Creates the unresolved fixture from the supplied dependencies and state.
  ///
  /// - Parameters:
  ///   - name: The immediate child folder name.
  ///   - issue: The unresolved parsing reason expected for this fixture.
  init(_ name: String, _ issue: ReleaseNameIssue) {
    self.name = name
    self.issue = issue
  }
}
