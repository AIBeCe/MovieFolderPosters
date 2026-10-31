import FileSystem
import Foundation
import Network
import Persistence
import Testing

@testable import MovieFolderCommon

/// Verifies persisted automatic-matching outcomes across adversarial titles and release evidence.
struct MovieFolderProcessorMatchingAcceptanceTests {
  /// Given two qualified Dune results, processing keeps the folder unresolved instead of choosing the first.
  @Test func competingQualifiedYearCandidatesRemainAmbiguous() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune (1984)")
    let exactYearMovie = movie(id: 1, title: "Dune", year: 1984)
    let nearbyMovie = movie(id: 2, title: "Dune", year: 1983)
    let provider = MatchingAcceptanceProvider(
      movies: [exactYearMovie, nearbyMovie],
      dates: [2: try releaseEvents([1983, 1984])])

    let summary = try await processor(fixture, provider: provider).process(root: fixture.movies)
    let saved = try savedState(fixture)
    let result = try #require(saved.folders["Dune (1984)"])

    #expect(summary.assigned == 0)
    #expect(result.status == .unresolved)
    #expect(result.processingReason == .ambiguousMovie)
    #expect(result.matchedMovieID == .none)
    #expect(fixture.assigner.assignmentCount == 0)
  }

  /// Given a one-edit title and complete theatrical years, processing still refuses a fuzzy-only identity.
  @Test func spellingSimilarityWithYearEvidenceDoesNotAssign() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Alian (1980)")
    let candidate = movie(id: 42, title: "Alien", year: 1979)
    let provider = MatchingAcceptanceProvider(
      movies: [candidate], dates: [42: try releaseEvents([1979, 1980])])

    let summary = try await processor(fixture, provider: provider).process(root: fixture.movies)
    let result = try #require(try savedState(fixture).folders["Alian (1980)"])

    #expect(summary.assigned == 0)
    #expect(result.status == .unresolved)
    #expect(result.matchedMovieID == .none)
    #expect(fixture.assigner.assignmentCount == 0)
  }

  /// Missing, one-sided, and non-theatrical events never authorize a nearby-year identity.
  @Test(arguments: [0, 1, 4, 5, 6])
  func incompleteOrIneligibleReleaseEventsDoNotAssign(eventType: Int) async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Alien (1980)")
    let candidate = movie(id: 42, title: "Alien", year: 1979)
    let years = eventType == 1 ? [1980] : [1979, 1980]
    let events = eventType == 0 ? [] : try releaseEvents(years, type: eventType)
    let provider = MatchingAcceptanceProvider(movies: [candidate], dates: [42: events])

    let summary = try await processor(fixture, provider: provider).process(root: fixture.movies)
    let result = try #require(try savedState(fixture).folders["Alien (1980)"])

    #expect(summary.assigned == 0)
    #expect(result.status == .unresolved)
    #expect(result.matchedMovieID == .none)
    #expect(fixture.assigner.assignmentCount == 0)
  }

  /// Builds the complete processing pipeline with fixture-owned storage and a recording poster adapter.
  /// - Parameters:
  ///   - fixture: Disposable folder, cache, and persistence stores.
  ///   - provider: Deterministic search and dated-release evidence.
  /// - Returns: A processor whose assignment attempts are observed by the fixture.
  private func processor(_ fixture: Fixture, provider: any MovieMetadataProvider) -> MovieFolderProcessor {
    MovieFolderProcessor(
      persistence: fixture.persistence, provider: provider,
      cacheDirectory: fixture.cache, posterAssigner: fixture.assigner)
  }

  /// Reads the persisted processing decision produced for the fixture root.
  /// - Parameter fixture: Disposable folder, cache, and persistence stores.
  /// - Returns: The saved processor state after the observable collection run.
  /// - Throws: Persistence access or decoding errors.
  private func savedState(_ fixture: Fixture) throws -> CollectionProcessingCache {
    let key = MovieFolderProcessor.processingStateKey(for: fixture.movies)
    let access = try #require(try fixture.persistence.acquireAccess(for: key))

    return try JSONDecoder().decode(CollectionProcessingCache.self, from: #require(try access.read()))
  }

  /// Creates deterministic provider metadata for an adversarial matching case.
  private func movie(id: Int, title: String, year: Int) -> MovieMetadata {
    MovieMetadata(id: id, title: title, originalTitle: title, releaseYear: year, posterPath: "/fixture.jpg")
  }

  /// Creates validated event fixtures while preserving the supplied provider type.
  /// - Parameters:
  ///   - years: Gregorian event years represented by the timestamps.
  ///   - type: TMDb release-event type.
  /// - Returns: Dated events with country and exact timestamp provenance.
  /// - Throws: `TMDbError.malformedResponse` if a fixture timestamp is invalid.
  private func releaseEvents(_ years: [Int], type: Int = 3) throws -> [MovieReleaseDate] {
    try years.map { year in
      try MovieReleaseDate(countryCode: "US", timestamp: "\(year)-05-25T00:00:00.000Z", type: type)
    }
  }
}

/// Deterministic provider exposing only the search and release evidence configured by a scenario.
private actor MatchingAcceptanceProvider: MovieMetadataProvider {
  /// Ordered search results returned to the processor.
  private let movies: [MovieMetadata]
  /// Complete dated events keyed by provider movie identity.
  private let dates: MovieReleaseDatesByID

  /// Creates a provider that never contacts TMDb or the user's credential store.
  /// - Parameters:
  ///   - movies: Ordered result list returned for every title query.
  ///   - dates: Complete release-event records keyed by movie ID.
  init(movies: [MovieMetadata], dates: MovieReleaseDatesByID) {
    self.movies = movies
    self.dates = dates
  }

  func searchMovies(title: String, year: Int?, language: TMDbLanguage) async throws -> MovieSearchResult {
    MovieSearchResult(movies: movies, hasMorePages: false)
  }

  func alternativeTitles(movieID: Int) async throws -> MovieAlternativeTitlesByID { [movieID: []] }

  func releaseDates(movieID: Int) async throws -> MovieReleaseDatesByID { [movieID: dates[movieID] ?? []] }

  func downloadPoster(path: String) async throws -> Data { throw TMDbError.invalidConfiguration }
}
