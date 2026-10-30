import FileSystem
import Foundation
@testable import MovieFolderCommon
import Network
import Persistence
import Testing

/// Language changes retain confirmed identities without forcing their replacement.
@Test func languageOnlyChangeRetainsConfirmedIdentity() throws {
  var state = ProcessingState()
  state.movieMatchingConfiguration = MovieMatchingConfiguration()
  state.folders["Alien"] = FolderRecord(fingerprint: "same", status: .processed, matchedMovieID: 42,
    posterPath: "/alien.jpg", movieIdentitySource: .conservativeMatch)
  state.updateMatchingConfiguration(MovieMatchingConfiguration(searchLanguage: try TMDbLanguage("pt-BR")))
  #expect(state.folders["Alien"]?.matchedMovieID == 42)
  #expect(state.folders["Alien"]?.requiresAutomaticReview != true)
}

/// Verified exact aliases join direct titles without choosing an artwork-bearing tie.
@Test func verifiedAliasEvidenceRemainsConservative() {
  let first = MovieMetadata(id: 1, title: "Alien", originalTitle: "Alien", releaseYear: 1979, posterPath: "/a.jpg")
  let second = MovieMetadata(id: 2, title: "Other", originalTitle: "Other", releaseYear: 1979, posterPath: .none)
  let search = MovieSearchResult(movies: [first, second], hasMorePages: false)
  let titles: MovieAlternativeTitles = [1: [], 2: [MovieAlternativeTitle(countryCode: "BR", title: "Alien", type: "")]]
  #expect(MovieMatcher().matchMovie(title: "Alien", year: 1979, search: search, alternativeTitles: titles)
    == .unresolved(.ambiguous))
  #expect(MovieMatcher().matchMovie(title: "Alien", year: 1979, search: search, alternativeTitles: [1: []])
    == .unresolved(.incompleteTitleEvidence))
}

/// A confirmed identity remains meaningful even when TMDb has no artwork for it.
@Test func languageChangeRetainsIdentityWithoutArtwork() throws {
  var state = ProcessingState()
  state.folders["Alien"] = FolderRecord(fingerprint: "same", status: .unresolved, matchedMovieID: 42,
    posterPath: .none, processingReason: .missingArtwork, movieTitle: "Alien", movieYear: 1979,
    movieIdentitySource: .conservativeMatch)
  state.updateMatchingConfiguration(MovieMatchingConfiguration(searchLanguage: try TMDbLanguage("pt-BR")))
  #expect(state.folders["Alien"]?.matchedMovieID == 42)
  #expect(state.folders["Alien"]?.movieTitle == "Alien")
}

/// Records each independent alias boundary without downloading or assigning artwork.
private actor AliasEvidenceProvider: MovieMetadataProvider {
  /// Requested identities in their observed sequential order.
  private(set) var requestedIDs = [Int]()
  /// A controlled failure stops the current assessment.
  let failure: TMDbError?
  /// Creates a provider with completed empty evidence or one controlled failure.
  init(failure: TMDbError? = .none) { self.failure = failure }
  func searchMovies(title: String, year: Int?, language: TMDbLanguage) -> MovieSearchResult {
    MovieSearchResult(movies: [], hasMorePages: false)
  }
  /// Supplies completed release events for this provider.
  func releaseDates(movieID: Int) throws -> MovieReleaseDates { [movieID: []] }
  func alternativeTitles(movieID: Int) throws -> MovieAlternativeTitles {
    requestedIDs.append(movieID)
    if let failure { throw failure }

    return [movieID: []]
  }
  func downloadPoster(path: String) throws -> Data { throw TMDbError.invalidImage }
}

/// Five candidates consume at most five calls; six consume none even with populated alias cache.
@Test func alternativeTitleBudgetAndEmptyCacheReuse() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  let provider = AliasEvidenceProvider()
  let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache, now: { Date(timeIntervalSince1970: 10_000) })
  var state = ProcessingState()
  let movies = (1...6).map {
    MovieMetadata(id: $0, title: "Movie \($0)", originalTitle: "Movie \($0)", releaseYear: 1979, posterPath: .none)
  }
  let five = MovieSearchResult(movies: Array(movies.prefix(5)), hasMorePages: false)
  _ = try await processor.assessMovie(title: "Alien", year: 1979, search: five, state: &state)
  #expect(await provider.requestedIDs == [1, 2, 3, 4, 5])
  #expect(state.alternativeTitles.count == 5)
  _ = try await processor.assessMovie(title: "Alien", year: 1979, search: five, state: &state)
  #expect(await provider.requestedIDs.count == 5)
  let result = try await processor.assessMovie(title: "Alien", year: 1979,
    search: MovieSearchResult(movies: movies, hasMorePages: false), state: &state)
  #expect(result == .unresolved(.incompleteTitleEvidence))
  #expect(await provider.requestedIDs.count == 5)
  _ = try await processor.assessMovie(title: "Alien", year: 1979,
    search: MovieSearchResult(movies: [movies[0]], hasMorePages: true), state: &state)
  #expect(await provider.requestedIDs.count == 5)
}

/// Expired completed evidence is refetched; provider failures never cache an empty success or proceed.
@Test func alternativeTitleExpiryAndFailure() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  let provider = AliasEvidenceProvider()
  let earlier = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache, now: { Date(timeIntervalSince1970: 10_000) })
  let later = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache, now: { Date(timeIntervalSince1970: 100_000) })
  let search = MovieSearchResult(movies: [MovieMetadata(id: 42, title: "Alien", originalTitle: "Alien",
    releaseYear: 1979, posterPath: .none)], hasMorePages: false)
  var state = ProcessingState()
  _ = try await earlier.assessMovie(title: "Alien", year: 1979, search: search, state: &state)
  _ = try await later.assessMovie(title: "Alien", year: 1979, search: search, state: &state)
  #expect(await provider.requestedIDs == [42, 42])
  let failing = AliasEvidenceProvider(failure: .authentication)
  let processor = MovieFolderProcessor(
    persistence: fixture.persistence, provider: failing, cacheDirectory: fixture.cache)
  var empty = ProcessingState()
  await #expect(throws: TMDbError.authentication) {
    try await processor.assessMovie(title: "Alien", year: 1979, search: search, state: &empty)
  }
  #expect(empty.alternativeTitles.isEmpty)
}

/// Structured request keys isolate exact title spellings, language, credentials and fixture context.
@Test func metadataCacheKeysIsolateRequestContext() throws {
  let base = try MovieFolderProcessor.queryKey(title: "Alien", year: 1979)
  #expect(base == (try MovieFolderProcessor.queryKey(title: " Alien ", year: 1979)))
  #expect(base != (try MovieFolderProcessor.queryKey(title: "alien", year: 1979)))
  #expect(base != (try MovieFolderProcessor.queryKey(title: "Alien", year: 1979, language: TMDbLanguage("pt-BR"))))
  #expect(base != (try MovieFolderProcessor.queryKey(title: "Alien", year: 1979, credentialRevision: UUID())))
  #expect(base != (try MovieFolderProcessor.queryKey(title: "Alien", year: 1979, usesFixtures: true)))
}

/// Alias eviction is deterministic and cannot discard unrelated confirmed folder decisions.
@Test func alternativeTitleCacheBoundsKeepDecisions() throws {
  var state = ProcessingState()
  state.folders["Alien"] = FolderRecord(fingerprint: "same", status: .processed, matchedMovieID: 42, posterPath: .none)
  for id in 1...129 {
    state.alternativeTitles[String(format: "%03d", id)] = CachedAlternativeTitles(movieID: id, titles: [],
      createdAt: Date(timeIntervalSince1970: Double(id)))
  }
  try state.boundAlternativeTitleCache()
  #expect(state.alternativeTitles.count == 128)
  #expect(!state.alternativeTitles.keys.contains("001"))
  #expect(state.folders["Alien"]?.matchedMovieID == 42)
  let title = MovieAlternativeTitle(countryCode: "US", title: String(repeating: "a", count: 600 * 1_024), type: "")
  state.alternativeTitles["big"] = CachedAlternativeTitles(movieID: 999, titles: [title], createdAt: .distantFuture)
  try state.boundAlternativeTitleCache()
  #expect(try JSONEncoder().encode(state.alternativeTitles).count <= 512 * 1_024)
  #expect(state.folders["Alien"]?.matchedMovieID == 42)
}

/// Exact aliases identify independently of artwork, without accepting an alias from the wrong release year.
@Test func verifiedAliasExactMatchAndYearBoundary() {
  let movie = MovieMetadata(id: 42, title: "Alien", originalTitle: "Alien", releaseYear: 1979, posterPath: .none)
  let search = MovieSearchResult(movies: [movie], hasMorePages: false)
  let evidence: MovieAlternativeTitles = [42: [MovieAlternativeTitle(countryCode: "BR",
    title: "O Oitavo Passageiro", type: "")]]
  #expect(MovieMatcher().matchMovie(title: "O Oitavo Passageiro", year: 1979,
    search: search, alternativeTitles: evidence) == .matched(movie))
  #expect(MovieMatcher().matchMovie(title: "O Oitavo Passageiro", year: 1980,
    search: search, alternativeTitles: evidence, releaseDates: [42: []]) == .unresolved(.noSuitableMatch))
}

/// Reassessment cannot silently replace a confirmed identity for an unchanged folder fingerprint.
@Test func automaticReassessmentRequiresExplicitIdentityChange() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Alien (1979)")
  let candidate = try FileSystemService().readCurrentState(ofChild: "Alien (1979)", in: fixture.movies)
  var state = ProcessingState()
  state.folders[candidate.name] = FolderRecord(fingerprint: candidate.fingerprint, status: .processed,
    matchedMovieID: 42, posterPath: "/old.jpg", movieTitle: "Original identity", movieYear: 1979,
    movieIdentitySource: .conservativeMatch, requiresAutomaticReview: true)
  do {
    let access = try #require(try fixture.persistence.acquireAccess(for:
      MovieFolderProcessor.processingStateKey(for: fixture.movies)))
    try access.write(JSONEncoder().encode(state))
  }
  let provider = CountingProvider(search: MovieSearchResult(movies: [MovieMetadata(id: 43, title: "Alien",
    originalTitle: "Alien", releaseYear: 1979, posterPath: "/new.jpg")], hasMorePages: false))
  let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner)
  #expect(try await processor.process(root: fixture.movies).unresolved == 1)
  #expect(fixture.assigner.assignmentCount == 0)
  #expect(await provider.posterCount == 0)
  let access = try #require(try fixture.persistence.acquireAccess(for:
    MovieFolderProcessor.processingStateKey(for: fixture.movies)))
  let retained = try await processor.loadState(from: access).folders[candidate.name]
  #expect(retained?.matchedMovieID == 42)
  #expect(retained?.posterPath == "/old.jpg")
  #expect(retained?.processingReason == .manualMatchingRequired)
  #expect(retained?.movieIdentitySource == .conservativeMatch)
}

/// A failed provider assessment retains operational and presentation identity evidence.
@Test func failedReassessmentRetainsConfirmedIdentity() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Alien (1979)")
  let candidate = try FileSystemService().readCurrentState(ofChild: "Alien (1979)", in: fixture.movies)
  var state = ProcessingState()
  state.folders[candidate.name] = FolderRecord(fingerprint: candidate.fingerprint, status: .processed,
    matchedMovieID: 42, posterPath: "/old.jpg", movieTitle: "Alien", movieYear: 1979,
    movieIdentitySource: .conservativeMatch, requiresAutomaticReview: true)
  do {
    let access = try #require(try fixture.persistence.acquireAccess(for:
      MovieFolderProcessor.processingStateKey(for: fixture.movies)))
    try access.write(JSONEncoder().encode(state))
  }
  let provider = CountingProvider(searchError: .authentication)
  let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner)
  _ = try await processor.process(root: fixture.movies)
  let access = try #require(try fixture.persistence.acquireAccess(for:
    MovieFolderProcessor.processingStateKey(for: fixture.movies)))
  let retained = try await processor.loadState(from: access).folders[candidate.name]
  #expect(retained?.matchedMovieID == 42)
  #expect(retained?.posterPath == "/old.jpg")
  #expect(retained?.movieIdentitySource == .conservativeMatch)
}

/// Identity evidence without usable artwork must retain the manual refresh no-poster contract.
@Test(arguments: [nil, "", "  "] as [String?])
func refreshRejectsMissingOrBlankArtworkBeforeDownload(path: String?) async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Alien (1979)")
  let candidate = try FileSystemService().readCurrentState(ofChild: "Alien (1979)", in: fixture.movies)
  let provider = CountingProvider(search: MovieSearchResult(movies: [MovieMetadata(id: 42, title: "Alien",
    originalTitle: "Alien", releaseYear: 1979, posterPath: path)], hasMorePages: false))
  let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner)
  await #expect(throws: PosterActionError.noPoster) {
    try await processor.refreshPoster(root: fixture.movies, child: candidate.name, expectedIdentity: candidate.identity)
  }
  #expect(await provider.posterCount == 0)
  #expect(fixture.assigner.assignmentCount == 0)
  #expect(try !FileSystemService().readCurrentState(ofChild: candidate.name, in: fixture.movies).hasCustomIcon)
}
