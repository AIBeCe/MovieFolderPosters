import FileSystem
import Foundation
@testable import MovieFolderCommon
import Network
import Persistence
import Testing

/// Nearby primary years and unknown primary years remain candidates before metadata budgets are applied.
@Test func releaseYearCandidatesIncludeNearbyAndUnknown() {
  let movies = [1978, 1979, 1980, 1981, nil].enumerated().map { index, year in
    MovieMetadata(id: index + 1, title: "Alien", originalTitle: "Alien", releaseYear: year, posterPath: "/a.jpg")
  }
  #expect(MovieMatcher().candidateIDs(year: 1979, search: MovieSearchResult(movies: movies, hasMorePages: false))
    == [1, 2, 3, 5])
}

/// Supplies deterministic first-page metadata and complete or deliberately incomplete evidence.
private actor ReleaseYearProvider: MovieMetadataProvider {
  /// Search results in provider order.
  let movies: [MovieMetadata]
  /// Whether unseen search pages remain.
  let hasMorePages: Bool
  /// Raw release evidence keyed by requested identity.
  let dates: MovieReleaseDates
  /// Optional provider aliases.
  let aliases: MovieAlternativeTitles
  /// Returns intentionally malformed map shapes without fixture sanitization.
  let returnsRawDates: Bool
  /// Whether date evidence waits for the test to cancel the processing task.
  let delaysDates: Bool
  /// Continuation for one suspended release endpoint.
  private var dateContinuation: CheckedContinuation<MovieReleaseDates, Error>?
  /// Signals that release evidence has been requested.
  private var dateStarted: CheckedContinuation<Void, Never>?
  /// Controlled date endpoint failure.
  let dateError: TMDbError?
  /// Controlled artwork endpoint failure.
  let posterError: TMDbError?
  /// Records ordered request categories and IDs.
  private(set) var requests = [String]()
  /// Captures discovery years, including absence.
  private(set) var searchYears = [Int?]()

  /// Creates isolated evidence without external services or credentials.
  init(movies: [MovieMetadata], dates: MovieReleaseDates = [:], aliases: MovieAlternativeTitles = [:],
       hasMorePages: Bool = false, returnsRawDates: Bool = false, delaysDates: Bool = false,
       dateError: TMDbError? = .none, posterError: TMDbError? = .none) {
    self.movies = movies
    self.dates = dates
    self.aliases = aliases
    self.hasMorePages = hasMorePages
    self.returnsRawDates = returnsRawDates
    self.delaysDates = delaysDates
    self.dateError = dateError
    self.posterError = posterError
  }

  func searchMovies(title: String, year: Int?, language: TMDbLanguage) -> MovieSearchResult {
    searchYears.append(year)
    requests.append("search")

    return MovieSearchResult(movies: movies, hasMorePages: hasMorePages)
  }

  func alternativeTitles(movieID: Int) -> MovieAlternativeTitles {
    requests.append("aliases:\(movieID)")

    return [movieID: aliases[movieID] ?? []]
  }

  func releaseDates(movieID: Int) async throws -> MovieReleaseDates {
    requests.append("dates:\(movieID)")
    if delaysDates {
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          dateContinuation = continuation
          dateStarted?.resume()
          dateStarted = .none
        }
      } onCancel: {
        Task { await self.cancelDateRequest() }
      }
    }
    if let dateError { throw dateError }

    if returnsRawDates { return dates }

    return dates[movieID].map { [movieID: $0] } ?? dates
  }

  /// Waits deterministically until a date request reaches its suspension point.
  func waitForDateRequest() async {
    if dateContinuation != nil { return }
    await withCheckedContinuation { dateStarted = $0 }
  }

  /// Ends the fixture request using the same cancellation contract as transport.
  private func cancelDateRequest() {
    dateContinuation?.resume(throwing: CancellationError())
    dateContinuation = .none
  }

  func downloadPoster(path: String) async throws -> Data {
    requests.append("poster")
    if let posterError { throw posterError }

    return try await CountingProvider().downloadPoster(path: path)
  }
}

/// Creates one exact-title provider movie, optionally withholding primary year or artwork.
private func releaseYearMovie(_ id: Int, year: Int? = 1979, title: String = "Alien",
                              poster: String? = "/alien.jpg") -> MovieMetadata {
  MovieMetadata(id: id, title: title, originalTitle: title, releaseYear: year, posterPath: poster)
}

/// Builds dated theatrical evidence using real validated event values.
private func releaseYearEvents(_ years: [Int], type: Int = 3) throws -> [MovieReleaseDate] {
  try years.map { try MovieReleaseDate(countryCode: "US", timestamp: "\($0)-05-25T00:00:00.000Z", type: type) }
}

/// Completed same-ID theatrical events authorize an alternative year after all aliases complete.
@Test func releaseYearAssessmentUsesAliasesThenDatedEvidence() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  let movie = releaseYearMovie(42)
  let events = try releaseYearEvents([1979, 1980])
  let provider = ReleaseYearProvider(movies: [movie, releaseYearMovie(43, year: 1980, title: "Other")],
    dates: [42: events])
  let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache)
  var state = ProcessingState()
  let search = MovieSearchResult(movies: [movie, releaseYearMovie(43, year: 1980, title: "Other")], hasMorePages: false)
  #expect(try await processor.assessMovie(title: "Alien", year: 1980, search: search, state: &state)
    == .matched(movie, releaseDates: events))
  #expect(await provider.requests == ["aliases:42", "aliases:43", "dates:42"])
  _ = try await processor.assessMovie(title: "Alien", year: 1980, search: search, state: &state)
  #expect(await provider.requests == ["aliases:42", "aliases:43", "dates:42", "dates:42"])
}

/// Exact primary and corroborated nearby identities compete only after year qualification.
@Test func releaseYearQualificationControlsAmbiguity() throws {
  let exact = releaseYearMovie(1, year: 1980)
  let nearby = releaseYearMovie(2)
  let search = MovieSearchResult(movies: [exact, nearby], hasMorePages: false)
  let aliases: MovieAlternativeTitles = [1: [], 2: []]
  let matcher = MovieMatcher()
  #expect(matcher.matchMovie(title: "Alien", year: 1980, search: search,
    alternativeTitles: aliases, releaseDates: [2: try releaseYearEvents([1979, 1980])]) == .unresolved(.ambiguous))
  #expect(matcher.matchMovie(title: "Alien", year: 1980, search: search,
    alternativeTitles: aliases, releaseDates: [2: []]) == .matched(exact))
  #expect(matcher.matchMovie(title: "Alien", year: 1980, search: search,
    alternativeTitles: aliases) == .unresolved(.incompleteYearEvidence))
  let unknown = MovieSearchResult(movies: [exact, releaseYearMovie(2, year: .none)], hasMorePages: false)
  #expect(matcher.matchMovie(title: "Alien", year: 1980, search: unknown,
    alternativeTitles: aliases) == .unresolved(.incompleteYearEvidence))
}

/// Numeric closeness, one-sided years, non-theatrical releases, and fuzzy titles never authorize identity.
@Test(arguments: [1, 2, 3, 4, 5, 6, 99])
func releaseYearRequiresBothEligibleEventYears(type: Int) throws {
  let movie = releaseYearMovie(42)
  let search = MovieSearchResult(movies: [movie], hasMorePages: false)
  let matcher = MovieMatcher()
  let complete = try releaseYearEvents([1979, 1980], type: type)
  let result = matcher.matchMovie(title: "Alien", year: 1980, search: search, alternativeTitles: [42: []],
    releaseDates: [42: complete])
  #expect(result == ((1...3).contains(type) ? .matched(movie, releaseDates: complete) : .unresolved(.noSuitableMatch)))
  #expect(matcher.matchMovie(title: "Alien", year: 1980, search: search, alternativeTitles: [42: []],
    releaseDates: [42: try releaseYearEvents([1980], type: type)]) == .unresolved(.noSuitableMatch))
  #expect(matcher.matchMovie(title: "Alian", year: 1980, search: search, alternativeTitles: [42: []],
    releaseDates: [42: complete]) == .unresolved(.noSuitableMatch))
}

/// Missing or wrong-ID evidence blocks instead of silently excluding a competing nearby movie.
@Test(arguments: [MovieReleaseDates(), [43: []], [42: [], 43: []]])
func releaseYearAssessmentRejectsIncompleteEvents(dates: MovieReleaseDates) async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  let movie = releaseYearMovie(42)
  let provider = ReleaseYearProvider(movies: [movie], dates: dates, returnsRawDates: true)
  let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache)
  var state = ProcessingState()
  #expect(try await processor.assessMovie(title: "Alien", year: 1980,
    search: MovieSearchResult(movies: [movie], hasMorePages: false), state: &state)
    == .unresolved(.incompleteYearEvidence))
}

/// Aliases may establish exact compatibility before provider events establish the year.
@Test func releaseYearAliasesAndBudgetRemainBounded() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  let movie = releaseYearMovie(42, title: "Localized")
  let events = try releaseYearEvents([1979, 1980])
  let alias = MovieAlternativeTitle(countryCode: "US", title: "Alien", type: "")
  let provider = ReleaseYearProvider(movies: [movie], dates: [42: events], aliases: [42: [alias]])
  let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache)
  var state = ProcessingState()
  #expect(try await processor.assessMovie(title: "Alien", year: 1980,
    search: MovieSearchResult(movies: [movie], hasMorePages: false), state: &state)
    == .matched(movie, releaseDates: events))
  let six = (1...6).map { releaseYearMovie($0) }
  #expect(try await processor.assessMovie(title: "Alien", year: 1980,
    search: MovieSearchResult(movies: six, hasMorePages: false), state: &state)
    == .unresolved(.incompleteTitleEvidence))
  #expect(try await processor.assessMovie(title: "Alien", year: 1980,
    search: MovieSearchResult(movies: [movie], hasMorePages: true), state: &state)
    == .unresolved(.incompleteSearch))
  #expect(await provider.requests == ["aliases:42", "dates:42"])
}

/// Real processing persists source primary year and raw accepted events through cache repair.
@Test func releaseYearProcessingRetainsProvenanceAndUnfilteredDiscovery() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Alien (1980)")
  let movie = releaseYearMovie(42)
  let events = try releaseYearEvents([1979, 1980])
  let provider = ReleaseYearProvider(movies: [movie], dates: [42: events])
  let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner)
  #expect(try await processor.process(root: fixture.movies).assigned == 1)
  #expect(await provider.searchYears.count == 1)
  #expect(await provider.searchYears.first == .some(.none))
  var state = try releaseYearSavedState(fixture)
  let record = try #require(state.folders["Alien (1980)"])
  #expect(record.movieYear == 1979)
  #expect(record.acceptedReleaseDates == events)
  #expect(record.movieYears() == [MovieYear(year: 1979, type: .primaryRelease),
    MovieYear(year: 1979, type: .theatrical), MovieYear(year: 1980, type: .theatrical)])
  let candidate = try FileSystemService().readCurrentState(ofChild: "Alien (1980)", in: fixture.movies)
  // The recording adapter leaves the icon absent, so the next run exercises saved-artwork reassignment.
  #expect(try await processor.process(root: fixture.movies).assigned == 1)
  state = try releaseYearSavedState(fixture)
  #expect(state.folders[candidate.name]?.acceptedReleaseDates == events)
  let source = fixture.cache.appendingPathComponent(MovieFolderProcessor.posterCacheName("/alien.jpg"))
  try FileManager.default.removeItem(at: source)
  #expect(try await processor.process(root: fixture.movies).assigned == 1)
  #expect(try releaseYearSavedState(fixture).folders[candidate.name]?.acceptedReleaseDates == events)
}

/// Successful year assessment survives missing artwork and post-match provider failure.
@Test(arguments: [true, false])
func releaseYearProcessingRetainsProvenanceWithoutArtwork(missingPoster: Bool) async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Alien (1980)")
  let events = try releaseYearEvents([1979, 1980])
  let provider = ReleaseYearProvider(movies: [releaseYearMovie(42, poster: missingPoster ? .none : "/a.jpg")],
    dates: [42: events], posterError: missingPoster ? .none : .httpStatus(503))
  let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner)
  _ = try await processor.process(root: fixture.movies)
  let record = try #require(try releaseYearSavedState(fixture).folders["Alien (1980)"])
  #expect(record.matchedMovieID == 42)
  #expect(record.acceptedReleaseDates == events)
  #expect(record.movieYear == 1979)
  #expect(fixture.assigner.assignmentCount == 0)
}

/// Historic year-based unresolved outcomes receive one fresh assessment and then become stable.
@Test(arguments: [FolderProcessingReason.noSuitableMovie, .ambiguousMovie])
func releaseYearHistoricAssessmentRunsOnce(reason: FolderProcessingReason) async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Alien (1980)")
  let candidate = try FileSystemService().readCurrentState(ofChild: "Alien (1980)", in: fixture.movies)
  let stale = CachedSearch(result: MovieSearchResult(movies: [releaseYearMovie(42)], hasMorePages: false),
    createdAt: Date())
  var state = ProcessingState(folders: [candidate.name: FolderRecord(fingerprint: candidate.fingerprint,
    status: .unresolved, retryDate: .distantFuture, matchedMovieID: .none, posterPath: .none,
    processingReason: reason)],
    queries: [try MovieFolderProcessor.queryKey(title: "Alien", year: .none): stale, "keep": stale])
  do {
    let access = try #require(try fixture.persistence.acquireAccess(for:
      MovieFolderProcessor.processingStateKey(for: fixture.movies)))
    try access.write(JSONEncoder().encode(state))
  }
  let provider = ReleaseYearProvider(movies: [])
  let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner)
  #expect(try await processor.process(root: fixture.movies).examined == 1)
  #expect(try await processor.process(root: fixture.movies).examined == 0)
  #expect(await provider.requests == ["search"])
  state = try releaseYearSavedState(fixture)
  #expect(state.folders[candidate.name]?.savedMatchingRulesVersion == MovieFolderProcessor.savedMatchingRulesVersion)
  #expect(state.queries.keys.contains("keep"))
}

/// Five candidates use eleven metadata requests including search; cached aliases cannot bypass the six-ID refusal.
@Test func releaseYearAssessmentEnforcesElevenRequestCeiling() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Alien (1980)")
  let movies = (1...5).map { releaseYearMovie($0) }
  let events = try releaseYearEvents([1979, 1980])
  let provider = ReleaseYearProvider(movies: movies,
    dates: Dictionary(uniqueKeysWithValues: (1...5).map { ($0, events) }))
  let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner)
  #expect(try await processor.process(root: fixture.movies).unresolved == 1)
  #expect(await provider.requests == ["search", "aliases:1", "aliases:2", "aliases:3", "aliases:4", "aliases:5",
    "dates:1", "dates:2", "dates:3", "dates:4", "dates:5"])
  #expect(fixture.assigner.assignmentCount == 0)
  var state = try releaseYearSavedState(fixture)
  #expect(state.alternativeTitles.count == 5)
  #expect(try await processor.assessMovie(title: "Alien", year: 1980,
    search: MovieSearchResult(movies: movies + [releaseYearMovie(6)], hasMorePages: false), state: &state)
    == .unresolved(.incompleteTitleEvidence))
  #expect(await provider.requests.count == 11)
}

/// A date endpoint failure is forwarded through recovery and prevents all artwork and folder mutation.
@Test(arguments: [TMDbError.rateLimited(retryAfter: "30"), .malformedResponse, .authentication])
func releaseYearProviderFailurePreservesRecoveryAndSafety(error: TMDbError) async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Alien (1980)")
  let provider = ReleaseYearProvider(movies: [releaseYearMovie(42)], dateError: error)
  let recovery = ProcessingRecoveryService(
    store: try PersistenceStore(directory: fixture.base.appendingPathComponent("Recovery")))
  let processor = MovieFolderProcessor(persistence: fixture.persistence,
    provider: RecoveryMovieMetadataProvider(provider: provider, recovery: recovery, credential: "fixture"),
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner, recovery: recovery)
  _ = try await processor.process(root: fixture.movies)
  let record = try #require(try releaseYearSavedState(fixture).folders["Alien (1980)"])
  let expected: FolderProcessingReason = switch error {
  case .rateLimited: .rateLimited
  case .authentication: .authentication
  default: .invalidResponse
  }
  #expect(record.processingReason == expected)
  #expect(record.matchedMovieID == .none)
  #expect(record.savedMatchingRulesVersion == .none)
  #expect(fixture.assigner.assignmentCount == 0)
  #expect(await provider.requests == ["search", "aliases:42", "dates:42"])
  #expect(try recovery.read().providerRetryAt != .none || expected == .authentication)
}

/// Fresh and saved Refresh retain dated provenance; an explicit same-ID choice clears automatic evidence.
@Test func releaseYearRefreshAndExplicitSelectionProvenance() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Alien (1980)")
  let events = try releaseYearEvents([1979, 1980])
  let movie = releaseYearMovie(42)
  let provider = ReleaseYearProvider(movies: [movie], dates: [42: events])
  let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache)
  let candidate = try FileSystemService().readCurrentState(ofChild: "Alien (1980)", in: fixture.movies)
  #expect(try await processor.refreshPoster(root: fixture.movies, child: candidate.name,
    expectedIdentity: candidate.identity) == 42)
  #expect(try releaseYearSavedState(fixture).folders[candidate.name]?.acceptedReleaseDates == events)
  #expect(try await processor.refreshPoster(root: fixture.movies, child: candidate.name,
    expectedIdentity: candidate.identity) == 42)
  #expect(await provider.searchYears.count == 1)
  #expect(await provider.searchYears.first == .some(.none))
  #expect(try releaseYearSavedState(fixture).folders[candidate.name]?.acceptedReleaseDates == events)
  #expect(try await processor.applyMoviePoster(movie, root: fixture.movies, child: candidate.name,
    expectedIdentity: candidate.identity) == 42)
  let record = try #require(try releaseYearSavedState(fixture).folders[candidate.name])
  #expect(record.acceptedReleaseDates == .none)
  #expect(record.movieYear == 1979)
  #expect(record.movieIdentitySource == .explicitSelection)
}

/// Older schema-one folder records decode without optional event/revision fields; search cache equality remains exact.
@Test func releaseYearCompatibilityPreservesOldPrimaryMetadata() throws {
  let movie = releaseYearMovie(42)
  let result = MovieSearchResult(movies: [movie], hasMorePages: false)
  let cached = CachedSearch(result: result, createdAt: Date())
  #expect(try JSONDecoder().decode(CachedSearch.self, from: JSONEncoder().encode(cached)).searchResult() == result)
  let raw = Data("{\"fingerprint\":\"same\",\"status\":\"unresolved\",\"processingReason\":\"noSuitableMovie\"}".utf8)
  let old = try JSONDecoder().decode(FolderRecord.self, from: raw)
  #expect(old.acceptedReleaseDates == .none)
  #expect(old.savedMatchingRulesVersion == .none)
  #expect(movie.movieYear == MovieYear(year: 1979, type: .primaryRelease))
}

/// A failed source-cache repair retains the dated events supporting the confirmed identity.
@Test func releaseYearFailedRepairPreservesDatedEvidence() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Alien (1980)")
  let events = try releaseYearEvents([1979, 1980])
  let movie = releaseYearMovie(42)
  let successful = ReleaseYearProvider(movies: [movie], dates: [42: events])
  let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: successful,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner)
  #expect(try await processor.process(root: fixture.movies).assigned == 1)
  let source = fixture.cache.appendingPathComponent(MovieFolderProcessor.posterCacheName("/alien.jpg"))
  try FileManager.default.removeItem(at: source)
  let failing = ReleaseYearProvider(movies: [], posterError: .httpStatus(503))
  let repair = MovieFolderProcessor(persistence: fixture.persistence, provider: failing,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner)
  #expect(try await repair.process(root: fixture.movies).transientFailures == 1)
  #expect(try releaseYearSavedState(fixture).folders["Alien (1980)"]?.acceptedReleaseDates == events)
  #expect(await failing.requests == ["poster"])
}

/// Fresh exact-year reassessment retains current-identity provenance without importing another fingerprint's events.
@Test(arguments: [true, false], [true, false])
func releaseYearFreshExactAssessmentRetainsOnlyCurrentIdentity(refresh: Bool, sameFingerprint: Bool) async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Alien (1980)")
  let candidate = try FileSystemService().readCurrentState(ofChild: "Alien (1980)", in: fixture.movies)
  let events = try releaseYearEvents([1979, 1980])
  let saved = FolderRecord(fingerprint: sameFingerprint ? candidate.fingerprint : "obsolete", status: .processed,
    matchedMovieID: 42, posterPath: "/alien.jpg", movieTitle: "Alien", movieYear: 1979,
    movieIdentitySource: .conservativeMatch, requiresAutomaticReview: true, acceptedReleaseDates: events)
  do {
    let access = try #require(try fixture.persistence.acquireAccess(for:
      MovieFolderProcessor.processingStateKey(for: fixture.movies)))
    try access.write(JSONEncoder().encode(ProcessingState(folders: [candidate.name: saved])))
  }
  let provider = ReleaseYearProvider(movies: [releaseYearMovie(42, year: 1980)])
  let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner)
  if refresh {
    #expect(try await processor.refreshPoster(root: fixture.movies, child: candidate.name,
      expectedIdentity: candidate.identity) == 42)
  } else {
    #expect(try await processor.process(root: fixture.movies).assigned == 1)
  }
  let record = try #require(try releaseYearSavedState(fixture).folders[candidate.name])
  #expect(record.acceptedReleaseDates == (sameFingerprint ? events : []))
  #expect(record.movieYear == 1980)
  #expect(await provider.requests == ["search", "aliases:42", "poster"])
}

/// Cancelling during dated evidence never completes a matching revision or begins artwork.
@Test func releaseYearCancellationLeavesAssessmentIncomplete() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Alien (1980)")
  let provider = ReleaseYearProvider(movies: [releaseYearMovie(42)], delaysDates: true)
  let recovery = ProcessingRecoveryService(
    store: try PersistenceStore(directory: fixture.base.appendingPathComponent("Recovery")))
  let processor = MovieFolderProcessor(persistence: fixture.persistence,
    provider: RecoveryMovieMetadataProvider(provider: provider, recovery: recovery, credential: "fixture"),
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner, recovery: recovery)
  let task = Task { try await processor.process(root: fixture.movies) }
  await provider.waitForDateRequest()
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
  #expect(await provider.requests == ["search", "aliases:42", "dates:42"])
  #expect(fixture.assigner.assignmentCount == 0)
  #expect(try releaseYearSavedState(fixture).folders["Alien (1980)"]?.savedMatchingRulesVersion == .none)
  #expect(try recovery.read().providerRetryAt == .none)
}

/// Reads actual persisted operational records after a processing attempt releases its lease.
private func releaseYearSavedState(_ fixture: Fixture) throws -> ProcessingState {
  let access = try #require(try fixture.persistence.acquireAccess(for:
    MovieFolderProcessor.processingStateKey(for: fixture.movies)))
  let bytes = try #require(try access.read())

  return try JSONDecoder().decode(ProcessingState.self, from: bytes)
}
