import Foundation
@testable import Common
import Persistence
import Testing

/// Only bounded, explicitly identified bracket metadata may establish identity.
@Test func labelledIdentifierParsingIsBoundedAndTyped() {
  let parser = MovieIdentifierInformationParser()
  #expect(parser.parse("Alien (1979) [tmdb:348] [imdb-tt0078748]") ==
    .identified([.tmdb(348), .imdb("tt0078748")]))
  #expect(parser.parse("Alien [tmdb:348] [tmdb:348]") == .identified([.tmdb(348)]))
  #expect(parser.parse("Alien 348 [tvdb:348]") == .absent)
}

/// Malformed recognized labels and conflicts block weaker automatic fallback.
@Test(arguments: ["[tmdb:0]", "[tmdb:2147483648]", "[tmdb:99999999999999999999999]",
  "[imdb:tt123]", "[tmdb:nope]", "[imdb:tt0000000]",
  "[tmdb::348]", "[tmdb:348"])
func labelledIdentifierParsingRejectsInvalidInformation(suffix: String) {
  #expect(MovieIdentifierInformationParser().parse("Alien " + suffix) == .unusable)
}

/// Identity requests participate in shared rejection recovery before another remote boundary.
@Test func identifierProcessingRecordsAndHonorsAccessTokenRejection() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  let recovery = ProcessingRecoveryService(
    store: try PersistenceStore(directory: fixture.base.appendingPathComponent("recovery")))
  let underlying = IdentifierInformationProvider(fails: true, disagrees: false)
  let provider = RecoveryAwareMovieMetadataProvider(provider: underlying, recovery: recovery, accessToken: "fixture")
  await #expect(throws: MovieMetadataError.authentication) {
    try await provider.movie(movieID: 348, language: .english)
  }
  await #expect(throws: ProcessingRecoveryError.authenticationRequired) {
    try await provider.movie(imdbID: "tt0078748", language: .english)
  }
  #expect(await underlying.lookupCount == 1)
}

/// All identifiers must resolve consistently, without a weaker title search on disagreement or failure.
@Test(arguments: [false, true])
func identifierProcessingNeverFallsBackOnDisagreementOrFailure(fails: Bool) async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Alien (1979) [tmdb:348] [imdb:tt0078748]")
  let provider = IdentifierInformationProvider(fails: fails, disagrees: true)
  let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner)
  let summary = try await processor.process(root: fixture.movies)
  #expect(summary.assigned == 0)
  #expect(await provider.searchCount == 0)
  #expect(fixture.assigner.assignmentCount == 0)
}

/// A valid identifier establishes identity even when the folder has no useful title or release year.
@Test func identifierProcessingUsesDirectIdentity() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("[tmdb:348]")
  let provider = IdentifierInformationProvider(fails: false, disagrees: false, hasPoster: true)
  let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner)
  let summary = try await processor.process(root: fixture.movies)
  #expect(summary.assigned == 1)
  #expect(fixture.assigner.assignmentCount == 1)
  #expect(await provider.lookupCount == 1)
  #expect(await provider.searchCount == 0)
}

/// Supplies identity information without services or real poster mutation.
actor IdentifierInformationProvider: MovieMetadataProvider {
  /// Whether the direct provider boundary fails.
  let fails: Bool
  /// Whether the IMDb resolution points to a different movie.
  let disagrees: Bool
  /// Whether usable poster metadata accompanies the resolved identity.
  let hasPoster: Bool
  /// Weaker search calls, forbidden after identifier selection.
  private(set) var searchCount = 0
  /// Observed direct lookups.
  private(set) var lookupCount = 0

  /// Creates a deterministic identifier provider.
  init(fails: Bool, disagrees: Bool, hasPoster: Bool = false) {
    self.fails = fails
    self.disagrees = disagrees
    self.hasPoster = hasPoster
  }

  func movie(movieID: Int, language: MovieSearchLanguage) throws -> MovieMetadata? {
    lookupCount += 1
    if fails { throw MovieMetadataError.authentication }

    return MovieMetadata(id: movieID, title: "Alien", originalTitle: "Alien", releaseYear: 1979,
      posterPath: hasPoster ? "/fixture.png" : .none)
  }

  func movie(imdbID: String, language: MovieSearchLanguage) throws -> MovieMetadata? {
    try movie(movieID: disagrees ? 349 : 348, language: language)
  }

  func searchMoviePage(title: String, year: Int?, language: MovieSearchLanguage, page: Int) throws -> MovieSearchPage {
    searchCount += 1
    throw MovieMetadataError.invalidQuery
  }

  func alternativeTitles(movieID: Int) throws -> MovieAlternativeTitlesByID { [movieID: []] }
  func releaseDates(movieID: Int) throws -> MovieReleaseDatesByID { [movieID: []] }
  func downloadPoster(path: String) throws -> Data {
    let encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADUlEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"

    return try #require(Data(base64Encoded: encoded))
  }
}

/// Distinct well-formed same-provider identities retain a specific contradiction classification.
@Test func labelledIdentifierParsingReportsConflicts() {
  #expect(MovieIdentifierInformationParser().parse("Alien [tmdb:348] [tmdb:349]") == .conflicting)
}
