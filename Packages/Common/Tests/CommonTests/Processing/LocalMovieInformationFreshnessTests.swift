import FileSystem
import Foundation
@testable import Common
import Persistence
import Synchronization
import Testing

/// Unchanged local information preserves manual resolution; a changed NFO permits a new automatic assessment.
@Test func localInformationFreshnessReassessesChangedUnresolvedInformation() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  let name = "Unclear (2021) (2022)"
  try fixture.addFolder(name)
  let nfo = fixture.movies.appendingPathComponent(name + "/movie.nfo")
  try Data("<movie><!--private-source-R120--><title>Unknown</title><year>2021</year></movie>".utf8).write(to: nfo)
  let initial = CountingProvider(search: MovieSearchResult(movies: [], hasMorePages: false))
  let configuration = MovieMatchingConfiguration(readsNFOInformation: true)
  let first = MovieFolderProcessor(persistence: fixture.persistence, provider: initial,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner, movieMatchingConfiguration: configuration)
  #expect(try await first.process(root: fixture.movies).unresolved == 1)
  do {
    let access = try #require(try fixture.persistence.acquireAccess(for:
      MovieFolderProcessor.processingStateKey(for: fixture.movies)))
    let bytes = try #require(try access.read())
    let cache = try JSONDecoder().decode(CollectionProcessingCache.self, from: bytes)
    #expect(cache.folders[name]?.localInformationReadResultSHA256?.count == 64)
    let operationalText = try #require(String(bytes: bytes, encoding: .utf8))
    #expect(!operationalText.contains("private-source-R120"))
  }
  let provider = CountingProvider()
  let next = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner, movieMatchingConfiguration: configuration)
  #expect(try await next.process(root: fixture.movies).assigned == 0)
  #expect(await provider.searchCount == 0)
  try Data("<movie><title>Dune</title><year>2021</year></movie>".utf8).write(to: nfo)
  #expect(try await next.process(root: fixture.movies).assigned == 1)
  #expect(await provider.searchCount == 1)
}

/// Local metadata changed while search or artwork is awaited cannot authorize assignment of the old movie.
@Test(arguments: [false, true])
func localInformationFreshnessDiscardsInFlightChanges(duringArtwork: Bool) async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  let name = "Unclear (2021) (2022)"
  try fixture.addFolder(name)
  let nfo = fixture.movies.appendingPathComponent(name + "/movie.nfo")
  try Data("<movie><title>Dune</title><year>2021</year></movie>".utf8).write(to: nfo)
  let provider = CountingProvider(delaysSearch: !duringArtwork, delaysPoster: duringArtwork)
  let informationReader = CountingInformationReader()
  let processor = MovieFolderProcessor(informationReader: informationReader,
    persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner,
    movieMatchingConfiguration: MovieMatchingConfiguration(readsNFOInformation: true))
  let task = Task { try await processor.process(root: fixture.movies) }
  if duringArtwork { await provider.waitForPoster() } else { await provider.waitForSearch() }
  let readsBeforeChange = informationReader.readCount
  #expect(readsBeforeChange > 0)
  try Data("<movie><title>Alien</title><year>1979</year></movie>".utf8).write(to: nfo)
  if duringArtwork { try await provider.allowPoster() } else { await provider.allowSearch() }
  let summary = try await task.value
  #expect(informationReader.readCount > readsBeforeChange)
  #expect(summary.assigned == 0)
  #expect(fixture.assigner.assignmentCount == 0)
  let access = try #require(try fixture.persistence.acquireAccess(for:
    MovieFolderProcessor.processingStateKey(for: fixture.movies)))
  let cache = try JSONDecoder().decode(CollectionProcessingCache.self, from: #require(try access.read()))
  #expect(cache.folders[name]?.matchedMovieID == .none)
}

/// Records freshness reads while retaining real directory identity and file evidence.
private final class CountingInformationReader: MovieFolderInformationReading {
  private let count = Mutex(0)
  var readCount: Int { count.withLock { $0 } }

  func movieInformation(
    toChild name: String, in directory: URL, expectedIdentity: String, options: MovieFolderInformationOptions
  ) throws -> MovieFolderInformationReadResult {
    count.withLock { $0 += 1 }

    return try FileSystemService().movieInformation(
      toChild: name, in: directory, expectedIdentity: expectedIdentity, options: options)
  }
}

/// A changed source may restore the same saved movie, but cannot replace a confirmed or explicit identity.
@Test(arguments: [false, true])
func localInformationFreshnessPreservesConfirmedIdentity(explicit: Bool) async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  let name = "Unclear (2021) (2022)"
  try fixture.addFolder(name)
  let nfo = fixture.movies.appendingPathComponent(name + "/movie.nfo")
  try Data("<movie><title>Dune</title><year>2021</year></movie>".utf8).write(to: nfo)
  let configuration = MovieMatchingConfiguration(readsNFOInformation: true)
  let first = MovieFolderProcessor(persistence: fixture.persistence, provider: CountingProvider(),
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner, movieMatchingConfiguration: configuration)
  #expect(try await first.process(root: fixture.movies).assigned == 1)
  let key = MovieFolderProcessor.processingStateKey(for: fixture.movies)
  var originalSHA256: String?
  do {
    let access = try #require(try fixture.persistence.acquireAccess(for: key))
    var cache = try JSONDecoder().decode(CollectionProcessingCache.self, from: #require(try access.read()))
  originalSHA256 = cache.folders[name]?.localInformationReadResultSHA256
  #expect(originalSHA256 != .none)
    if explicit { cache.folders[name]?.movieIdentitySource = .explicitSelection }
    try access.write(JSONEncoder().encode(cache))
  }
  try Data("<movie><uniqueid type=\"tmdb\">999</uniqueid></movie>".utf8).write(to: nfo)
  let provider = CountingProvider()
  let next = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner, movieMatchingConfiguration: configuration)
  _ = try await next.process(root: fixture.movies)
  #expect(await provider.searchCount == 0)
  let access = try #require(try fixture.persistence.acquireAccess(for: key))
  let saved = try JSONDecoder().decode(CollectionProcessingCache.self, from: #require(try access.read()))
  #expect(saved.folders[name]?.matchedMovieID == 42)
  #expect(saved.folders[name]?.localInformationReadResultSHA256 == originalSHA256)
  if explicit { #expect(saved.folders[name]?.movieIdentitySource == .explicitSelection) }
}

/// The final synchronous authorization boundary rechecks local information before invoking the icon adapter.
@Test func localInformationFreshnessChecksInsideFinalAssignmentFence() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  let name = "Unclear (2021) (2022)"
  try fixture.addFolder(name)
  let nfo = fixture.movies.appendingPathComponent(name + "/movie.nfo")
  try Data("<movie><title>Dune</title><year>2021</year></movie>".utf8).write(to: nfo)
  let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: CountingProvider(),
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner,
    processingVerifier: InformationMutationVerifier(nfo: nfo),
    movieMatchingConfiguration: MovieMatchingConfiguration(readsNFOInformation: true))
  #expect(try await processor.process(root: fixture.movies).assigned == 0)
  #expect(fixture.assigner.assignmentCount == 0)
}

/// Refresh uses fresh local automatic information only while its captured input contract remains current.
@Test func localInformationFreshnessProtectsFreshRefreshSelection() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  let name = "Unclear (2021) (2022)"
  try fixture.addFolder(name)
  let nfo = fixture.movies.appendingPathComponent(name + "/movie.nfo")
  try Data("<movie><title>Dune</title><year>2021</year></movie>".utf8).write(to: nfo)
  let candidate = try #require(FileSystemService().candidates(in: fixture.movies).first)
  let provider = CountingProvider(delaysSearch: true, posterError: .invalidConfiguration)
  let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner,
    movieMatchingConfiguration: MovieMatchingConfiguration(readsNFOInformation: true))
  let task = Task { try await processor.refreshPoster(root: fixture.movies, child: name,
    expectedIdentity: candidate.identity)
  }
  await provider.waitForSearch()
  try Data("<movie><title>Alien</title><year>1979</year></movie>".utf8).write(to: nfo)
  await provider.allowSearch()
  await #expect(throws: AutomaticProcessingIssue.changedInformation) { try await task.value }
  #expect(await provider.posterCount == 0)
}

/// Makes a deterministic external edit at the same boundary that revalidates current authorization.
private struct InformationMutationVerifier: MovieFolderProcessingVerifier {
  /// Disposable fixture file to change before final assignment.
  let nfo: URL
  func checkAutomaticProcessing(in root: URL) throws -> PersistenceAccess? { .none }
  func checkIconChange(
    _ change: MovieFolderIconChange,
    to candidate: MovieFolderCandidate,
    in root: URL
  ) throws -> PersistenceAccess? {
    if change == .automaticPosterAssignment {
      try Data("<movie><title>Alien</title><year>1979</year></movie>".utf8).write(to: nfo)
    }

    return .none
  }
}

/// Old unconfirmed labelled-folder decisions are assessed once even with every local source disabled.
@Test func localInformationFreshnessAdoptsLegacyLabelledIdentifiersWithoutOptions() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  let name = "Alien [tmdb:348]"
  try fixture.addFolder(name)
  let candidate = try #require(FileSystemService().candidates(in: fixture.movies).first)
  var record = FolderProcessingCacheRecord(fingerprint: candidate.fingerprint, status: .unresolved,
    retryDate: .none, matchedMovieID: .none, posterPath: .none, processingReason: .noSuitableMovie)
  record.savedMatchingRulesVersion = 1
  do {
    let access = try #require(try fixture.persistence.acquireAccess(for:
      MovieFolderProcessor.processingStateKey(for: fixture.movies)))
    try access.write(JSONEncoder().encode(CollectionProcessingCache(folders: [name: record])))
  }
  let provider = IdentifierInformationProvider(fails: false, disagrees: false, hasPoster: true)
  let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner)
  #expect(try await processor.process(root: fixture.movies).assigned == 1)
  _ = try await processor.process(root: fixture.movies)
  #expect(await provider.lookupCount == 1)
  #expect(await provider.searchCount == 0)
}

/// Changed local input reopens a selected negative assessment; another edit during its provider wait discards it.
@Test(arguments: [false, true])
func localInformationFreshnessProtectsSelectedRetry(changesWhileWaiting: Bool) async throws {
  let scenario = try ManualResolutionScenario(isAmbiguous: false)
  let fixture = scenario.fixture
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  let repository = ConfigurationRepository(store: try PersistenceStore(
    directory: fixture.base.appendingPathComponent("Settings")))
  let matching = MovieMatchingConfiguration(readsNFOInformation: true)
  try repository.update { $0.movieMatchingConfiguration = matching }
  let original = scenario.processingContext
  let context = CollectionProcessingContext(rootID: original.rootID, rootIdentity: original.rootIdentity,
    authorizationVersion: original.authorizationVersion, credentialRevision: original.credentialRevision,
    usesStubTMDbResponses: false, appearance: .softFinish, movieMatchingConfiguration: matching,
    processingConfigurationRevision: original.processingConfigurationRevision)
  let name = "Dune (2021)"
  let nfo = fixture.movies.appendingPathComponent(name + "/movie.nfo")
  try Data("<movie><title>Unknown</title><year>2021</year></movie>".utf8).write(to: nfo)
  let initial = MovieFolderProcessor(persistence: fixture.persistence, provider: scenario.provider,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner, processingStore: scenario.collectionStore,
    movieMatchingConfiguration: matching)
  #expect(try await initial.process(root: fixture.movies, processingContext: context).unresolved == 1)
  try Data("<movie><title>Dune</title><year>2021</year></movie>".utf8).write(to: nfo)
  let candidate = try #require(FileSystemService().candidates(in: fixture.movies).first)
  let provider = CountingProvider(delaysSearch: changesWhileWaiting)
  let next = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner, processingStore: scenario.collectionStore,
    movieMatchingConfiguration: matching)
  let task = Task { try await next.retryEligibleFolder(root: fixture.movies, child: name,
    expectedIdentity: candidate.identity, processingContext: context)
  }
  if changesWhileWaiting {
    await provider.waitForSearch()
    try Data("<movie><title>Alien</title><year>1979</year></movie>".utf8).write(to: nfo)
    await provider.allowSearch()
  }
  let result = try await task.value

  guard case .attempted(let summary, _) = result else { Issue.record("Changed information permits retry"); return }

  #expect(summary.assigned == (changesWhileWaiting ? 0 : 1))
  #expect(await provider.searchCount == 1)
}
