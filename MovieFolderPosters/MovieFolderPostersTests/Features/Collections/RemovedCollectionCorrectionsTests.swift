import Common
import Foundation
import Persistence
import Synchronization
import Testing

@testable import MovieFolderPosters

/// Verifies committed collection removal and correction deletion using isolated real stores.
struct RemovedCollectionCorrectionsTests {
  /// A failed outcome cleanup cannot stop correction removal after the settings commit.
  @Test func removalDeletesCorrectionsEvenWhenOutcomeRemovalFails() async throws {
    let fixture = try CorrectionRemovalFixture()
    defer { fixture.cleanup() }
    let outcomeRemoval = RemovalOutcomeProbe(fails: true)
    let service = try fixture.service(outcomeRemoval: outcomeRemoval)

    try await service.removeDirectory(fixture.collectionID)

    #expect(try fixture.repository.read().directories.isEmpty)
    #expect(try fixture.corrections.correction(for: "folder", in: fixture.collectionID) == .none)
    #expect(outcomeRemoval.calls.withLock { $0 } == 1)
    #expect(try Data(contentsOf: fixture.movieContent) == Data("Movie contents".utf8))
  }

  /// Busy correction storage leaves removal committed, reports failure, and permits a later retry.
  @Test func busyCorrectionRecordCanBeRemovedAfterCollectionCommit() async throws {
    let fixture = try CorrectionRemovalFixture()
    defer { fixture.cleanup() }
    let outcomeRemoval = RemovalOutcomeProbe(fails: false)
    let activity = MovieFolderActivityServiceFake()
    let service = try fixture.service(outcomeRemoval: outcomeRemoval, activity: activity)
    let correctionDirectory = fixture.root.appendingPathComponent("FolderSearchCorrections")
    let correctionStore = try PersistenceStore(directory: correctionDirectory)
    do {
      let access = try #require(try correctionStore.acquireAccess(
        for: "folder-search-corrections:\(fixture.collectionID.uuidString)"))
      defer { withExtendedLifetime(access) {} }
      let original = try access.read()

      try await service.removeDirectory(fixture.collectionID)

      #expect(try fixture.repository.read().directories.isEmpty)
      #expect(try access.read() == original)
      #expect(outcomeRemoval.calls.withLock { $0 } == 1)
      let events = try await activity.entries()
      #expect(events.contains { $0.event.action == .collectionCleanup && $0.event.status == .failed })
    }

    try fixture.cleaner.cleanCorrectionsForRemovedCollections()
    #expect(try fixture.corrections.correction(for: "folder", in: fixture.collectionID) == .none)
  }

  /// Failed settings removal and settings contention cannot delete correction records.
  @Test func failedRemovalAndBusySettingsPreserveCorrections() async throws {
    let fixture = try CorrectionRemovalFixture()
    defer { fixture.cleanup() }
    let outcomeRemoval = RemovalOutcomeProbe(fails: false)
    let service = try fixture.service(outcomeRemoval: outcomeRemoval)
    await #expect(throws: ConfigurationError.directoryNotFound) {
      try await service.removeDirectory(UUID())
    }
    let (_, settingsLock) = try fixture.repository.readHoldingAccess()
    defer { withExtendedLifetime(settingsLock) {} }

    #expect(throws: ConfigurationError.busy) { try fixture.cleaner.cleanCorrectionsForRemovedCollections() }
    await #expect(throws: ConfigurationError.busy) { try await service.removeDirectory(fixture.collectionID) }
    #expect(try fixture.corrections.correction(for: "folder", in: fixture.collectionID) == fixture.correction)
    #expect(outcomeRemoval.calls.withLock { $0 } == 0)
  }
}

/// Supplies app storage locations rooted entirely beneath the test directory.
nonisolated private struct CorrectionRemovalLocations: MovieFolderApplicationStorageLocations {
  /// Parent of all disposable application data.
  let root: URL
  /// Resolves the isolated shared storage.
  func appGroupContainerURL() throws -> URL { root }
  /// Resolves the isolated private storage.
  func applicationSupportURL() throws -> URL { root }
}

/// Records outcome-removal calls independently of correction storage.
nonisolated private final class RemovalOutcomeProbe: CollectionProcessingCleaning {
  /// Number of attempted outcome-removal operations.
  let calls = Mutex(0)
  /// Whether the outcome operation should fail.
  let fails: Bool

  /// Creates a deterministic outcome-removal collaborator.
  init(fails: Bool) { self.fails = fails }

  /// Records the call and optionally reports storage contention.
  func pruneToConfiguredRoots() throws -> Set<String> {
    calls.withLock { $0 += 1 }

    if fails { throw ConfigurationError.busy }

    return []
  }
}

/// Owns a configured collection and the real correction namespace for each test.
nonisolated private struct CorrectionRemovalFixture {
  /// Parent of all temporary data.
  let root: URL
  /// Current configured collection identifier.
  let collectionID = UUID()
  /// Real settings repository.
  let repository: ConfigurationRepository
  /// Isolated correction store.
  let corrections: FolderSearchCorrectionStore
  /// Correction expected to survive failed deletion.
  let correction: FolderSearchCorrection
  /// Disposable movie file used to check the filesystem boundary.
  let movieContent: URL
  /// Deletion operation using isolated settings and storage locations.
  let cleaner: RemovedCollectionCorrectionsCleaner

  /// Creates a configured collection with saved correction data and one disposable content file.
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let movies = root.appendingPathComponent("Movies")
    try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
    movieContent = movies.appendingPathComponent("movie.mkv")
    try Data("Movie contents".utf8).write(to: movieContent)
    let services = MovieFolderServiceFactory(locations: CorrectionRemovalLocations(root: root))
    repository = try services.makeConfigurationRepository()
    let directory = MonitoredDirectory(id: collectionID, path: movies.path, transferBookmark: Data([1]),
      authorizationVersion: UUID())
    try repository.update { $0.directories = [directory] }
    corrections = try services.makeFolderSearchCorrectionStore()
    correction = try FolderSearchCorrection(title: "Movie", year: 1999)
    try corrections.setCorrection(correction, for: "folder", in: collectionID)
    cleaner = RemovedCollectionCorrectionsCleaner(repository: repository, services: services)
  }

  /// Creates the real removal service with independent outcome and correction operations.
  func service(
    outcomeRemoval: any CollectionProcessingCleaning,
    activity: any MovieFolderActivityServicing = MovieFolderActivityServiceFake()
  ) throws -> DirectoryConfigurationService {
    DirectoryConfigurationService(repository: repository,
      authorizations: try PersistenceStore(directory: root.appendingPathComponent("Authorization")),
      accessTokenStore: ConfigurationAccessTokenProbe(), notifier: SilentConfigurationNotifier(),
      processingCleanup: outcomeRemoval, activity: activity, removedCollectionCorrectionsCleaner: cleaner)
  }

  /// Removes the fixture's disposable files.
  func cleanup() { try? FileManager.default.removeItem(at: root) }
}
