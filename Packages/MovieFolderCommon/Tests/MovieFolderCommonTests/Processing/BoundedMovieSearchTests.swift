import CryptoKit
import Foundation
import Network
import Persistence
import Testing

@testable import MovieFolderCommon

/// Supplies explicitly scripted pages and rejects every unexpected request.
private actor PagedMovieProvider: MovieMetadataProvider {
  /// Requested pages, in dispatch order.
  private(set) var requests = [Int]()
  /// Independently requested title and date evidence.
  private(set) var evidenceRequests = [String]()
  /// Deterministic page outcomes keyed by requested number.
  let pages: [Int: Result<MovieSearchPage, TMDbError>]
  /// Whether the fixture cancels its own caller after a page response.
  let cancelsAfterPage: Int?
  /// Independent durable gate writer used between responses.
  let recoveryAfterFirstPage: ProcessingRecoveryService?
  /// Whether to establish backoff rather than enable recovery mode.
  let establishesBackoff: Bool

  /// Creates a finite fixture with no implied pages.
  init(_ pages: [Int: Result<MovieSearchPage, TMDbError>], cancelsAfterPage: Int? = .none,
       recoveryAfterFirstPage: ProcessingRecoveryService? = .none, establishesBackoff: Bool = false) {
    self.pages = pages
    self.cancelsAfterPage = cancelsAfterPage
    self.recoveryAfterFirstPage = recoveryAfterFirstPage
    self.establishesBackoff = establishesBackoff
  }

  func searchMoviePage(title: String, year: Int?, language: TMDbLanguage, page: Int) throws -> MovieSearchPage {
    requests.append(page)

    guard let response = pages[page] else { throw TMDbError.invalidQuery }

    if page == 1, let recoveryAfterFirstPage {
      if establishesBackoff {
        try recoveryAfterFirstPage.recordProviderFailure(TMDbError.rateLimited(retryAfter: "60"),
          credentialDigest: ProcessingRecoveryService.credentialDigest("fixture"))
      } else {
        try recoveryAfterFirstPage.setRecoveryModeEnabled(true)
      }
    }
    if cancelsAfterPage == page { withUnsafeCurrentTask { $0?.cancel() } }

    return try response.get()
  }

  func alternativeTitles(movieID: Int) throws -> MovieAlternativeTitlesByID {
    evidenceRequests.append("aliases:\(movieID)")

    return [movieID: []]
  }

  func releaseDates(movieID: Int) throws -> MovieReleaseDatesByID {
    evidenceRequests.append("dates:\(movieID)")

    return [movieID: [try MovieReleaseDate(countryCode: "US", timestamp: "2021-01-01T00:00:00Z", type: 3)]]
  }
  func downloadPoster(path: String) throws -> Data { throw TMDbError.invalidQuery }
}

/// Builds one stable record for duplicate and late-competitor scenarios.
private func paginationMovie(_ id: Int, title: String = "Dune") -> MovieMetadata {
  MovieMetadata(id: id, title: title, originalTitle: title, releaseYear: 2021, posterPath: "/movie.jpg")
}

/// Completion stops at the provider boundary and never spends unused budget.
@Test(arguments: [1, 2, 3, 5]) func boundedSearchStopsAtCompletion(total: Int) async throws {
  let pages = Dictionary(uniqueKeysWithValues: (1...total).map {
    ($0, Result<MovieSearchPage, TMDbError>.success(
      MovieSearchPage(movies: [paginationMovie($0)], page: $0, totalPages: total)))
  })
  let provider = PagedMovieProvider(pages)
  let result = try await provider.searchMovies(title: "Dune", year: 2021, language: .english, pageLimit: 5)
  #expect(result.movies.map(\.id) == Array(1...total))
  #expect(!result.hasMorePages)
  #expect(await provider.requests == Array(1...total))
}

/// Budget exhaustion remains incomplete even when every fetched page looks uniquely matched.
@Test(arguments: [1, 3, 5]) func boundedSearchPreservesExhaustion(limit: Int) async throws {
  let pages = Dictionary(uniqueKeysWithValues: (1...limit).map {
    ($0, Result<MovieSearchPage, TMDbError>.success(
      MovieSearchPage(movies: [paginationMovie(1)], page: $0, totalPages: 6)))
  })
  let provider = PagedMovieProvider(pages)
  let result = try await provider.searchMovies(title: "Dune", year: 2021, language: .english, pageLimit: limit)
  #expect(result.movies == [paginationMovie(1)])
  #expect(result.hasMorePages)
  #expect(await provider.requests == Array(1...limit))
}

/// A later exact competitor is collected before matching, and identical records keep first-seen order.
@Test func boundedSearchIncludesLateCompetitor() async throws {
  let provider = PagedMovieProvider([
    1: .success(MovieSearchPage(movies: [paginationMovie(2)], page: 1, totalPages: 2)),
    2: .success(MovieSearchPage(movies: [paginationMovie(2), paginationMovie(1)], page: 2, totalPages: 2))
  ])
  let result = try await provider.searchMovies(title: "Dune", year: 2021, language: .english, pageLimit: 3)
  #expect(result.movies.map(\.id) == [2, 1])
  #expect(MovieMatcher().match(title: "Dune", year: 2021, search: result) == .unresolved(.ambiguous))
}

/// Metadata changes, wrong pages, duplicate conflicts, and page failures never return partial success.
@Test(arguments: [0, 1, 2, 3]) func boundedSearchRejectsBrokenContinuation(failure: Int) async throws {
  let second: Result<MovieSearchPage, TMDbError> = switch failure {
  case 0: .success(MovieSearchPage(movies: [], page: 1, totalPages: 2))
  case 1: .success(MovieSearchPage(movies: [], page: 2, totalPages: 3))
  case 2: .success(MovieSearchPage(movies: [paginationMovie(1, title: "Other")], page: 2, totalPages: 2))
  default: .failure(.authentication)
  }
  let provider = PagedMovieProvider([
    1: .success(MovieSearchPage(movies: [paginationMovie(1)], page: 1, totalPages: 2)), 2: second
  ])
  await #expect(throws: failure == 3 ? TMDbError.authentication : TMDbError.malformedResponse) {
    try await provider.searchMovies(title: "Dune", year: 2021, language: .english, pageLimit: 3)
  }
}

/// Invalid budgets cannot dispatch a request.
@Test(arguments: [0, 6, -1]) func boundedSearchRejectsInvalidBudget(limit: Int) async {
  let provider = PagedMovieProvider([:])
  await #expect(throws: ConfigurationError.invalidConfiguration) {
    try await provider.searchMovies(title: "Dune", year: .none, language: .english, pageLimit: limit)
  }
  #expect(await provider.requests.isEmpty)
}

/// Cancellation after a response stops before the next request or publishing accumulated movies.
@Test func boundedSearchChecksCancellationAfterPage() async {
  let provider = PagedMovieProvider([
    1: .success(MovieSearchPage(movies: [paginationMovie(1)], page: 1, totalPages: 2))
  ], cancelsAfterPage: 1)
  let task = Task {
    try await provider.searchMovies(title: "Dune", year: .none, language: .english, pageLimit: 3)
  }
  await #expect(throws: CancellationError.self) { try await task.value }
  #expect(await provider.requests == [1])
}

/// A separate shared-store writer can pause or throttle the search between successful pages.
@Test(arguments: [false, true]) func boundedSearchRechecksSharedAdmission(backoff: Bool) async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let reader = ProcessingRecoveryService(store: try PersistenceStore(directory: directory))
  let writer = ProcessingRecoveryService(store: try PersistenceStore(directory: directory))
  let fixture = PagedMovieProvider([
    1: .success(MovieSearchPage(movies: [paginationMovie(1)], page: 1, totalPages: 2)),
    2: .success(MovieSearchPage(movies: [paginationMovie(2)], page: 2, totalPages: 2))
  ], recoveryAfterFirstPage: writer, establishesBackoff: backoff)
  let provider = RecoveryAwareMovieMetadataProvider(provider: fixture, recovery: reader, credential: "fixture")
  do {
    _ = try await provider.searchMovies(title: "Dune", year: 2021, language: .english, pageLimit: 3)
    Issue.record("Shared admission must prevent the second page")
  } catch let error as ProcessingRecoveryError {
    if backoff {
      guard case .providerBackoff = error else { Issue.record("Expected shared provider backoff"); return }
    } else {
      #expect(error == .recoveryMode)
    }
  }
  #expect(await fixture.requests == [1])
}

/// A larger captured budget must fetch its missing pages instead of reusing an incomplete smaller search.
@Test func boundedSearchCacheSeparatesLimitsAndPersistsLateAmbiguity() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Dune (2021)")
  let provider = PagedMovieProvider([
    1: .success(MovieSearchPage(movies: [paginationMovie(1)], page: 1, totalPages: 2)),
    2: .success(MovieSearchPage(movies: [paginationMovie(2)], page: 2, totalPages: 2))
  ])
  let timing = try MovieFolderProcessorConfiguration(incompleteSearchRetryInterval: 1,
    transientFailureRetryInterval: 1, queryCacheLifetime: 10_000, minimumProviderRetryInterval: 1,
    maximumProviderRetryInterval: 10)
  let first = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner,
    now: { Date(timeIntervalSince1970: 10_000) }, configuration: timing, searchPageLimit: 1)
  #expect(try await first.process(root: fixture.movies).unresolved == 1)
  let second = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner,
    now: { Date(timeIntervalSince1970: 10_002) }, configuration: timing, searchPageLimit: 2)
  #expect(try await second.process(root: fixture.movies).unresolved == 1)
  #expect(await provider.requests == [1, 1, 2])
  #expect(fixture.assigner.assignmentCount == 0)
  let access = try #require(try fixture.persistence.acquireAccess(for:
    MovieFolderProcessor.processingStateKey(for: fixture.movies)))
  let state = try await second.loadState(from: access)
  #expect(state.folders["Dune (2021)"]?.processingReason == .ambiguousMovie)
  #expect(state.folders["Dune (2021)"]?.matchedMovieID == .none)
  #expect(state.queries.count == 2)
}

/// A failed continuation cannot leave preceding pages in the successful query cache.
@Test func boundedSearchFailedPageNeverCachesPartialSearch() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Dune (2021)")
  let provider = PagedMovieProvider([
    1: .success(MovieSearchPage(movies: [paginationMovie(1)], page: 1, totalPages: 2)),
    2: .failure(.authentication)
  ])
  let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner, searchPageLimit: 3)
  _ = try await processor.process(root: fixture.movies)
  #expect(fixture.assigner.assignmentCount == 0)
  #expect(await provider.evidenceRequests.isEmpty)
  let access = try #require(try fixture.persistence.acquireAccess(for:
    MovieFolderProcessor.processingStateKey(for: fixture.movies)))
  let state = try await processor.loadState(from: access)
  #expect(state.queries.isEmpty)
  #expect(state.folders["Dune (2021)"]?.matchedMovieID == .none)
}

/// Five pages and five eligible identities consume exactly fifteen identification requests at most.
@Test func boundedSearchPreservesFifteenRequestCeilingAndAliasKeys() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Dune (2021)")
  let pages = Dictionary(uniqueKeysWithValues: (1...5).map { page in
    let movie = MovieMetadata(id: page, title: "Dune", originalTitle: "Dune", releaseYear: 2020,
      posterPath: "/movie.jpg")

    return (page, Result<MovieSearchPage, TMDbError>.success(
      MovieSearchPage(movies: [movie], page: page, totalPages: 5)))
  })
  let provider = PagedMovieProvider(pages)
  let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner, searchPageLimit: 5)
  #expect(try await processor.process(root: fixture.movies).unresolved == 1)
  #expect(await provider.requests == [1, 2, 3, 4, 5])
  #expect(await provider.evidenceRequests == ["aliases:1", "aliases:2", "aliases:3", "aliases:4", "aliases:5",
    "dates:1", "dates:2", "dates:3", "dates:4", "dates:5"])
  #expect(fixture.assigner.assignmentCount == 0)
  let access = try #require(try fixture.persistence.acquireAccess(for:
    MovieFolderProcessor.processingStateKey(for: fixture.movies)))
  let state = try await processor.loadState(from: access)
  let legacyKey = try JSONSerialization.data(withJSONObject: [
    "category": "alternativeTitles", "revision": 1, "movieID": 1, "language": "en-US", "usesFixtures": false
  ], options: [.sortedKeys])
  let digest = SHA256.hash(data: legacyKey).map { String(format: "%02x", $0) }.joined()
  #expect(state.alternativeTitles[digest]?.movieID == 1)
}
