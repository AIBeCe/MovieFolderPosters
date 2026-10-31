import Testing

@testable import MovieFolderParsing

/// Regression coverage for conservative release-name parsing.
struct ReleaseNameParserTests {
  /// Verifies extracts Title And Year.
  @Test func extractsTitleAndYear() {
    let expected = ParsedReleaseName(title: "The Drama", year: 2026)
    #expect(ReleaseNameParser().parse("The.Drama.2026") == .parsed(expected))
  }

  /// Verifies preserves Title Without Year.
  @Test func preservesTitleWithoutYear() {
    let expected = ParsedReleaseName(title: "Ride The Eagle", year: .none)
    #expect(ReleaseNameParser().parse("Ride.The.Eagle") == .parsed(expected))
  }

  /// Verifies normalizes Separators And Whitespace.
  @Test func normalizesSeparatorsAndWhitespace() {
    let expected = ParsedReleaseName(title: "North Star", year: 2023)
    #expect(ReleaseNameParser().parse("  North_Star  2023  ") == .parsed(expected))
  }

  /// Verifies rejects Empty Name.
  @Test func rejectsEmptyName() { #expect(ReleaseNameParser().parse("   ") == .unresolved(.emptyName)) }

  /// Database codes in a suffix do not become part of the search title or establish movie identity.
  @Test(arguments: [
    ReleaseNameParserFixture("Come and See (1985) [tt0091251]", "Come and See", 1985),
    ReleaseNameParserFixture("Stealth (2005) [imdb-tt0382992]", "Stealth", 2005),
    ReleaseNameParserFixture("Dune (2021) [tmdb-438631]", "Dune", 2021),
    ReleaseNameParserFixture("Dune (2021) [tvdb-12345]", "Dune", 2021),
    ReleaseNameParserFixture("Dune (2021) [wikidata-Q25188]", "Dune", 2021),
    ReleaseNameParserFixture("Dune (2021) [tt1160419] 2160p WEB-DL", "Dune", 2021),
    ReleaseNameParserFixture("Dune (2021) 2160p WEB-DL [tt1160419]", "Dune", 2021),
    ReleaseNameParserFixture("Dune (2021) [tt1160419] [tmdb-438631]", "Dune", 2021)
  ])
  func discardsDatabaseIdentifierSuffixes(_ fixture: ReleaseNameParserFixture) {
    let parser = ReleaseNameParser()

    #expect(parser.hasRecognizedDatabaseIdentifierSuffix(fixture.name))
    #expect(parser.parse(fixture.name) == .parsed(ParsedReleaseName(title: fixture.title, year: fixture.year)))
  }

  /// Complete edition phrases after a year are discarded while their title and year remain intact.
  @Test(arguments: [
    ReleaseNameParserFixture("Dune (2021) Director's Cut", "Dune", 2021),
    ReleaseNameParserFixture("Dune (2021) Director’s Cut 2160p WEB-DL", "Dune", 2021),
    ReleaseNameParserFixture("Dune (2021) Directors Cut 1080p BluRay", "Dune", 2021),
    ReleaseNameParserFixture("Dune (2021) dIrEcToR's cUt", "Dune", 2021),
    ReleaseNameParserFixture("Dune (2021) Collector's Edition", "Dune", 2021),
    ReleaseNameParserFixture("Dune (2021) Collector’s Edition HDR", "Dune", 2021),
    ReleaseNameParserFixture("Dune (2021) Collectors Edition", "Dune", 2021),
    ReleaseNameParserFixture("Dune (2021) Special Edition", "Dune", 2021),
    ReleaseNameParserFixture("Dune (2021) Final Cut", "Dune", 2021),
    ReleaseNameParserFixture("Dune (2021) Theatrical Cut", "Dune", 2021)
  ])
  func discardsCompleteEditionSuffixes(_ fixture: ReleaseNameParserFixture) {
    let parser = ReleaseNameParser()

    #expect(parser.hasRecognizedEditionSuffix(fixture.name))
    #expect(parser.parse(fixture.name) == .parsed(ParsedReleaseName(title: fixture.title, year: fixture.year)))
  }

  /// Incomplete edition phrases and conflicting years remain unresolved rather than being discarded.
  @Test(arguments: [
    UnresolvedReleaseNameFixture("Dune (2021) Director's 2160p", .ambiguousMetadata),
    UnresolvedReleaseNameFixture("Dune (2021) Special Cut 1080p", .ambiguousMetadata),
    UnresolvedReleaseNameFixture("Dune (2021) Final Cut Extra 2160p", .ambiguousMetadata),
    UnresolvedReleaseNameFixture("Dune (2021) Final Cut 2022", .ambiguousYear)
  ])
  func rejectsIncompleteEditionSuffixes(_ fixture: UnresolvedReleaseNameFixture) {
    let parser = ReleaseNameParser()

    #expect(!parser.hasRecognizedEditionSuffix(fixture.name))
    #expect(parser.parse(fixture.name) == .unresolved(fixture.issue))
  }

  /// Numeric titles and edition-like title words separated from a year remain part of the title.
  @Test(arguments: [
    ReleaseNameParserFixture("1984.Final.Cut", "1984 Final Cut", .none),
    ReleaseNameParserFixture("1917.Special.Edition", "1917 Special Edition", .none),
    ReleaseNameParserFixture("Summer.of.1984.The.Final.Cut", "Summer of 1984 The Final Cut", .none)
  ])
  func preservesEditionLikeTitleTokens(_ fixture: ReleaseNameParserFixture) {
    let parser = ReleaseNameParser()

    #expect(!parser.hasRecognizedEditionSuffix(fixture.name))
    #expect(parser.parse(fixture.name) == .parsed(ParsedReleaseName(title: fixture.title, year: fixture.year)))
  }

  /// Unknown bracketed text and identifiers embedded in titles remain available to conservative parsing.
  @Test(arguments: [
    UnresolvedReleaseNameFixture("Dune (2021) [unknown-12345]", .ambiguousMetadata),
    UnresolvedReleaseNameFixture("Dune (2021) [tt12]", .ambiguousMetadata)
  ])
  func doesNotDiscardUnsupportedOrEmbeddedTokens(_ fixture: UnresolvedReleaseNameFixture) {
    let parser = ReleaseNameParser()

    #expect(!parser.hasRecognizedDatabaseIdentifierSuffix(fixture.name))
    #expect(parser.parse(fixture.name) == .unresolved(fixture.issue))
  }

  /// A bracketed code inside a title is not reclassified as suffix metadata.
  @Test func preservesIdentifierShapedTitleToken() {
    let name = "Dune [tt1160419] Part Two (2024)"
    let parser = ReleaseNameParser()

    #expect(!parser.hasRecognizedDatabaseIdentifierSuffix(name))
    #expect(parser.parse(name) == .parsed(ParsedReleaseName(title: "Dune [tt1160419] Part Two", year: 2024)))
  }

  /// Checks that release annotations are removed without losing the movie title or year.
  ///
  /// - Parameter fixture: The input and expected outcome for this parameterized regression.
  @Test(arguments: [
    ReleaseNameParserFixture("The.Drama.2026.2160p.WEB-DL.DDP5.1.Atmos.H265-GROUP", "The Drama", 2026),
    ReleaseNameParserFixture("North.Star.2023.1080p.BluRay.x264-GROUP", "North Star", 2023),
    ReleaseNameParserFixture("Ride.The.Eagle.2021.1080p.WEB-DL-GROUP", "Ride The Eagle", 2021),
    ReleaseNameParserFixture("Spider-Man.No.Way.Home.2021.2160p.BluRay.x265-GROUP", "Spider-Man No Way Home", 2021),
    ReleaseNameParserFixture(
      "Whisper.Of.The.Heart.1995.NORDiC.1080p.WEB-DL.H.264.DDP5.1-NoTrace",
      "Whisper Of The Heart", 1995),
    ReleaseNameParserFixture("The.Drama.2026.REMASTERED.2160p.WEB-DL", "The Drama", 2026),
    ReleaseNameParserFixture("North.Star.WEB-DL.x264-GROUP", "North Star", .none),
    ReleaseNameParserFixture("Ride.The.Eagle.1080p.WEB-DL-GROUP", "Ride The Eagle", .none),
    ReleaseNameParserFixture("Movie.2020.x265-GROUP", "Movie", 2020),
    ReleaseNameParserFixture("Movie.[2020].HDR10+.HEVC.DDP5.1-GROUP", "Movie", 2020),
    ReleaseNameParserFixture(
      "When Marnie Was There [2014] 1080p BDRip x265 DTS-HD MA 5.0 Kira [SEV]",
      "When Marnie Was There", 2014),
    ReleaseNameParserFixture(
      "Batman Knightfall Part 1 2026 2160p UHD BluRay REMUX DV HDR HEVC DTS-HD MA 5.1-d3g",
      "Batman Knightfall Part 1", 2026)
  ])
  func extractsFullReleaseNames(_ fixture: ReleaseNameParserFixture) {
    #expect(
      ReleaseNameParser().parse(fixture.name)
        == .parsed(
          ParsedReleaseName(
            title: fixture.title,
            year: fixture.year)))
  }

  /// Checks that technical-looking tokens remain when they belong to the movie title.
  ///
  /// - Parameter fixture: The input and expected outcome for this parameterized regression.
  @Test(arguments: [
    ReleaseNameParserFixture("1917.2019.1080p.BluRay", "1917", 2019),
    ReleaseNameParserFixture("2001.A.Space.Odyssey.1968.1080p.BluRay", "2001 A Space Odyssey", 1968),
    ReleaseNameParserFixture("Blade.Runner.2049.[2017].2160p.WEB-DL", "Blade Runner 2049", 2017),
    ReleaseNameParserFixture("Summer.of.1984.(2000).1080p.WEB-DL", "Summer of 1984", 2000),
    ReleaseNameParserFixture("Remux.2023", "Remux", 2023),
    ReleaseNameParserFixture("The.Remux.Movie.2020.1080p.BluRay", "The Remux Movie", 2020),
    ReleaseNameParserFixture("The.Web.of.Life.2018", "The Web of Life", 2018),
    ReleaseNameParserFixture("The.Dolby.Vision.2020", "The Dolby Vision", 2020),
    ReleaseNameParserFixture("The.H265.Movie.2020", "The H265 Movie", 2020),
    ReleaseNameParserFixture("The.4K.Movie.2020", "The 4K Movie", 2020),
    ReleaseNameParserFixture("The.1080p.Movie", "The 1080p Movie", .none),
    ReleaseNameParserFixture("The.1984.Experiment", "The 1984 Experiment", .none),
    ReleaseNameParserFixture("1984", "1984", .none),
    ReleaseNameParserFixture("Movie.BluRay", "Movie BluRay", .none),
    ReleaseNameParserFixture("Amélie.(2001).1080p.BluRay", "Amélie", 2001),
    ReleaseNameParserFixture("Schindler's.List.1993.1080p.BluRay", "Schindler's List", 1993),
    ReleaseNameParserFixture("Dune.Final.Cut.(2021)", "Dune Final Cut", 2021)
  ])
  func preservesLegitimateTitleTokens(_ fixture: ReleaseNameParserFixture) {
    #expect(
      ReleaseNameParser().parse(fixture.name)
        == .parsed(
          ParsedReleaseName(
            title: fixture.title,
            year: fixture.year)))
  }

  /// Checks that uncertain release evidence remains explicitly unresolved.
  ///
  /// - Parameter fixture: The input and expected outcome for this parameterized regression.
  @Test(arguments: [
    UnresolvedReleaseNameFixture("Movie.1999.2000", .ambiguousYear),
    UnresolvedReleaseNameFixture("Movie.1999.2000.1080p.WEB-DL", .ambiguousYear),
    UnresolvedReleaseNameFixture("Blade.Runner.2049.2017.2160p.WEB-DL", .ambiguousYear),
    UnresolvedReleaseNameFixture("Movie.[1999].(2000).1080p.WEB-DL", .ambiguousYear),
    UnresolvedReleaseNameFixture("Movie.2020.Special.Edit.1080p", .ambiguousMetadata),
    UnresolvedReleaseNameFixture("1080p.WEB-DL.x265-GROUP", .missingTitle),
    UnresolvedReleaseNameFixture("[2020].1080p.WEB-DL", .missingTitle),
    UnresolvedReleaseNameFixture("(2020).1080p.BluRay", .missingTitle),
    UnresolvedReleaseNameFixture("Movie.[1999].1080p.(2000).WEB-DL", .ambiguousYear),
    UnresolvedReleaseNameFixture("Summer.of.1984.Remastered.[2000].1080p.WEB-DL", .ambiguousMetadata),
    UnresolvedReleaseNameFixture("The.BluRay.Remux.Movie.2020.1080p.WEB-DL", .ambiguousMetadata),
    UnresolvedReleaseNameFixture("The.4K.Vision.2020.1080p.WEB-DL", .ambiguousMetadata),
    UnresolvedReleaseNameFixture("The.Drama.2026...GROUP", .truncatedName),
    UnresolvedReleaseNameFixture("The.Drama…GROUP", .truncatedName),
    UnresolvedReleaseNameFixture("/Users/me/Movies", .invalidName)
  ])
  func reportsUncertainNames(_ fixture: UnresolvedReleaseNameFixture) {
    #expect(ReleaseNameParser().parse(fixture.name) == .unresolved(fixture.issue))
  }
}

/// A release folder name and the title/year interpretation expected by a parameterized test.
struct ReleaseNameParserFixture: Sendable {
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
struct UnresolvedReleaseNameFixture: Sendable {
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
