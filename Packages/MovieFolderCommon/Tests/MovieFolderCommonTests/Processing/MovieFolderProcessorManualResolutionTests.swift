import CryptoKit
import Darwin
import FileSystem
import Foundation
import Network
import Persistence
import Testing

@testable import MovieFolderCommon

/// Prepares the persisted collection context used by manual-resolution regression tests.
struct ManualResolutionScenario {
  /// Temporary movie folders and stores isolated from the user's files.
  let fixture: Fixture
  /// Clock used to expire legacy retry metadata.
  let clock: TestClock
  /// Provider configured with the selected negative search response.
  let provider: CountingProvider
  /// Identifier of the configured collection root.
  let rootID: UUID
  /// Persisted settings context used by processing operations.
  let processingContext: CollectionProcessingContext
  /// Store retaining confirmed negative folder assessments.
  let collectionStore: CollectionProcessingStore
  /// Processor configured to update the fixture's outcomes.
  let processor: MovieFolderProcessor

  /// Creates a persisted scenario with either ambiguous candidates or no suitable metadata match.
  ///
  /// - Parameter isAmbiguous: Whether the provider returns competing candidates rather than an empty search.
  /// - Throws: Fixture setup, filesystem identity, or persistence errors.
  init(isAmbiguous: Bool) throws {
    let fixture = try Fixture()
    self.fixture = fixture
    try fixture.addFolder("Dune (2021)")
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    self.clock = clock
    let search: MovieSearchResult = isAmbiguous
      ? MovieSearchResult(movies: [
        MovieMetadata(id: 1, title: "Dune", originalTitle: "Dune", releaseYear: 2021, posterPath: "/one.jpg"),
        MovieMetadata(id: 2, title: "Dune", originalTitle: "Dune", releaseYear: 2021, posterPath: "/two.jpg")
      ], hasMorePages: false)
      : MovieSearchResult(movies: [], hasMorePages: false)
    let provider = CountingProvider(search: search)
    self.provider = provider
    let rootID = UUID()
    self.rootID = rootID
    let authorizationVersion = UUID()
    let rootIdentity = try FileSystemService().persistentDirectoryIdentity(at: fixture.movies)
    let configuration = ConfigurationRepository(
      store: try PersistenceStore(directory: fixture.base.appendingPathComponent("Settings")))
    let monitoredDirectory = MonitoredDirectory(
      id: rootID, path: fixture.movies.path, transferBookmark: Data([1]),
      authorizationVersion: authorizationVersion, identity: rootIdentity)
    try configuration.update { $0.directories = [monitoredDirectory] }
    let settings = try configuration.read()
    let context = CollectionProcessingContext(
      rootID: rootID, rootIdentity: rootIdentity, authorizationVersion: authorizationVersion,
      credentialRevision: settings.credentialRevision, usesStubTMDbResponses: false, appearance: .softFinish,
      processingConfigurationRevision: monitoredDirectory.processingConfiguration.revision)
    processingContext = context
    let collectionStore = CollectionProcessingStore(
      store: try PersistenceStore(
        directory: fixture.base.appendingPathComponent("Outcomes"), maximumRecordBytes: 8 * 1024 * 1024),
      configuration: configuration)
    self.collectionStore = collectionStore
    processor = try fixture.processor(
      provider: provider, clock: { clock.now }, processingStore: collectionStore)
  }

  /// Adds the legacy retry date that an earlier format could persist for a completed negative result.
  func setLegacyRetryDate() throws {
    let canonicalPath = fixture.movies.resolvingSymlinksInPath().standardizedFileURL.path
    let cacheKey = "movie-folder-processing:\(canonicalPath)"
    let access = try #require(try fixture.persistence.acquireAccess(for: cacheKey))
    let data = try #require(try access.read())
    let saved = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var folders = try #require(saved["folders"] as? [String: [String: Any]])
    var dune = try #require(folders["Dune (2021)"])
    #expect(dune["retryDate"] == nil)
    dune["retryDate"] = clock.now.addingTimeInterval(86_400).timeIntervalSinceReferenceDate
    folders["Dune (2021)"] = dune
    var legacyState = saved
    legacyState["folders"] = folders
    try access.write(JSONSerialization.data(withJSONObject: legacyState))
  }
}

/// Confirms completed negative matches remain eligible only for explicit manual resolution.
@Test(arguments: [false, true])
func confirmedManualResolutionDoesNotRepeatAfterRetryExpiryAndProcessorRestart(isAmbiguous: Bool) async throws {
  let scenario = try ManualResolutionScenario(isAmbiguous: isAmbiguous)
  let fixture = scenario.fixture
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  let first = try await scenario.processor.process(
    root: fixture.movies, processingContext: scenario.processingContext)
  let expectedState: FolderProcessingState = isAmbiguous ? .severalMatches : .notFound
  let firstAssessment = try #require(
    try scenario.collectionStore.read(rootID: scenario.rootID)?.folders.first)
  #expect(firstAssessment.processingState == expectedState)
  #expect(firstAssessment.processingReason == (isAmbiguous ? .ambiguousMovie : .noSuitableMovie))
  #expect(firstAssessment.nextRetryAt == .none)
  let expectedReason: FolderProcessingReason = isAmbiguous ? .ambiguousMovie : .noSuitableMovie
  try scenario.setLegacyRetryDate()
  let second = try await scenario.processor.process(
    root: fixture.movies, processingContext: scenario.processingContext)
  let secondAssessment = try #require(
    try scenario.collectionStore.read(rootID: scenario.rootID)?.folders.first)
  #expect(secondAssessment.processingState == expectedState)
  #expect(secondAssessment.processingReason == expectedReason)
  #expect(secondAssessment.nextRetryAt == .none)
  scenario.clock.advance(by: 86_401)
  let restartedProcessor = try fixture.processor(
    provider: scenario.provider, clock: { scenario.clock.now },
    processingStore: scenario.collectionStore)
  let afterExpiry = try await restartedProcessor.process(
    root: fixture.movies, processingContext: scenario.processingContext)
  let restartedAssessment = try #require(
    try scenario.collectionStore.read(rootID: scenario.rootID)?.folders.first)
  #expect(restartedAssessment.processingState == expectedState)
  #expect(restartedAssessment.processingReason == expectedReason)
  #expect(restartedAssessment.nextRetryAt == .none)

  #expect(first.unresolved == 1)
  #expect(second.unresolved == 1)
  #expect(second.skippedRetryWindow == 0)
  #expect(afterExpiry.examined == 0)
  #expect(afterExpiry.unresolved == 1)
  #expect(afterExpiry.skippedRetryWindow == 0)
  #expect(await scenario.provider.searchCount == 1)
  #expect(fixture.assigner.assignmentCount == 0)
}
