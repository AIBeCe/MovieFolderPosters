import FileSystem
import Foundation
import Persistence
import Testing

@testable import MovieFolderCommon

/// Regression coverage for shared settings validation, persistence, and access ordering.
struct DirectoryConfigurationTests {
  /// New settings persist behavior-equivalent matching defaults for both processes.
  @Test func matchingDefaultsArePersisted() throws {
    let encoded = try JSONEncoder().encode(DirectoryConfiguration())
    let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let configuration = try #require(fields["movieMatchingConfiguration"] as? [String: Any])
    #expect(configuration["requiresReleaseYearForAutomaticMatching"] as? Bool == false)
    #expect(configuration["comparesOriginalTitles"] as? Bool == true)
    #expect(configuration["searchLanguage"] as? String == "en-US")
  }

  /// Inclusion changes fence processing, while repeated requests preserve the active revision.
  @Test func processingConfigurationRotatesOnlyForEffectiveChanges() {
    var configuration = CollectionProcessingConfiguration()
    let initialRevision = configuration.revision

    let unchangedPause = configuration.setPaused(false)
    #expect(!unchangedPause)
    #expect(configuration.revision == initialRevision)
    let paused = configuration.setPaused(true)
    #expect(paused)
    #expect(configuration.revision != initialRevision)
    let pausedRevision = configuration.revision
    let repeatedPause = configuration.setPaused(true)
    #expect(!repeatedPause)
    #expect(configuration.revision == pausedRevision)

    let excluded = configuration.excludeFolder(identity: "movie-id", lastKnownName: "Movie 2020")
    #expect(excluded)
    let excludedRevision = configuration.revision
    let repeatedExclusion = configuration.excludeFolder(identity: "movie-id", lastKnownName: "Movie 2020")
    #expect(!repeatedExclusion)
    #expect(configuration.revision == excludedRevision)
    let refreshedName = configuration.refreshExcludedFolderName(identity: "movie-id", lastKnownName: "Renamed Movie")
    #expect(refreshedName)
    let renamedRevision = configuration.revision
    let repeatedName = configuration.refreshExcludedFolderName(identity: "movie-id", lastKnownName: "Renamed Movie")
    #expect(!repeatedName)
    #expect(configuration.revision == renamedRevision)
    let included = configuration.includeFolder(identity: "movie-id")
    #expect(included)
    let repeatedInclusion = configuration.includeFolder(identity: "movie-id")
    #expect(!repeatedInclusion)
  }

  /// Legacy roots default to active inclusion; v3 roots preserve saved policies.
  @Test func explicitMigrationPreservesInclusionAndRoundTripsCurrentSchema() throws {
    let rootID = UUID()
    let revision = UUID()
    let authorization = UUID()
    let legacyJSON = """
      {"version":2,"directories":[{"id":"\(rootID)","path":"/Movies","transferBookmark":"AQ==",
      "authorizationVersion":"\(authorization)"}],"credentialRevision":"\(revision)",
      "processingCacheRevision":"\(revision)","developmentFixtures":false}
      """
    let legacy = try convertLegacySettingsFixture(Data(legacyJSON.utf8))
    #expect(legacy.directories[0].processingConfiguration.isPaused == false)
    #expect(legacy.directories[0].processingConfiguration.excludedFolders.isEmpty)

    var current = legacy
    var configuration = current.directories[0].processingConfiguration
    let paused = configuration.setPaused(true)
    let excluded = configuration.excludeFolder(identity: "volume:object", lastKnownName: "Film")
    #expect(paused)
    #expect(excluded)
    current.directories[0].processingConfiguration = configuration
    let data = try JSONEncoder().encode(current)
    let reopened = try JSONDecoder().decode(DirectoryConfiguration.self, from: data)
    #expect(reopened.directories[0].processingConfiguration == configuration)
    #expect(reopened.directories[0].isPaused)
    #expect(reopened.directories[0].excludesFolder(identity: "volume:object"))
  }

  /// Legacy decoding assigns one stable generation so settings rereads do not stale their own leases.
  @Test func legacyInclusionRevisionIsStableAcrossReadsAndChangeAccess() throws {
    let rootID = UUID()
    let authorization = UUID()
    let revision = UUID()
    let legacyJSON = """
      {"version":2,"directories":[{"id":"\(rootID)","path":"/Movies","transferBookmark":"AQ==",
      "authorizationVersion":"\(authorization)"}],"credentialRevision":"\(revision)",
      "processingCacheRevision":"\(revision)","developmentFixtures":false}
      """
    let data = Data(legacyJSON.utf8)
    let firstDecode = try convertLegacySettingsFixture(data)
    let secondDecode = try convertLegacySettingsFixture(data)
    let firstConfigurationRevision = try #require(firstDecode.directories.first?.processingConfiguration.revision)
    #expect(secondDecode.directories.first?.processingConfiguration.revision == firstConfigurationRevision)

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try PersistenceStore(directory: directory)
    do {
      let writeAccess = try #require(try store.acquireAccess(for: ConfigurationRepository.recordKey))
      try writeAccess.write(data)
      withExtendedLifetime(writeAccess) {}
    }

    let repository = ConfigurationRepository(store: store)
    #expect(throws: MovieFolderStorageMigrationError.migrationRequired(record: .settings, version: 2)) {
      try repository.read()
    }
    let migrator = MovieFolderStorageMigrator(configurationStore: store,
      collectionOutcomeStore: try PersistenceStore(directory: directory.appendingPathComponent("Outcomes")),
      backupStore: try PersistenceStore(directory: directory.appendingPathComponent("Backups")))
    _ = try migrator.migrate()
    let configuration = try repository.read()
    let savedDirectory = try #require(configuration.directories.first)
    let configurationAccessForIconChange = try repository.configurationAccessForIconChange(
      for: savedDirectory, expectedConfiguration: configuration)
    withExtendedLifetime(configurationAccessForIconChange) {}
  }
  /// Access failures must describe a recovery action consistent with the assessed evidence.
  @Test(arguments: [
    (MovieFolderCommon.DirectoryAvailability.available, "not verified"),
    (.unavailable, "Refresh Status"),
    (.reauthorizationRequired, "Locate Folder"),
    (.checkUnavailable, "busy"),
    (.disconnected, "Reconnect"),
    (.missing, "not found"),
    (.readOnly, "write access"),
    (.unsupported, "unsupported"),
    (.identityChanged, "identity has changed"),
    (.compatibilityUnknown, "unverified"),
    (.overlapping, "Remove one")
  ])
  func accessEvidenceExplainsRecovery(availability: MovieFolderCommon.DirectoryAvailability, guidance: String) {
    #expect(availability.explanation.contains(guidance))
  }

  /// Verifies change Access Rejects New Overlap Even When Target Root Is Unchanged.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func configurationAccessForIconChangeRejectsNewOverlapEvenWhenTargetRootIsUnchanged() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = ConfigurationRepository(store: try PersistenceStore(directory: root))
    let target = MonitoredDirectory(
      id: UUID(), path: "/Movies", transferBookmark: Data([1]),
      authorizationVersion: UUID(), identity: "target")
    let other = MonitoredDirectory(
      id: UUID(), path: "/Other", transferBookmark: Data([2]),
      authorizationVersion: UUID(), identity: "other")
    try repository.update { $0.directories = [target, other] }
    let before = try repository.read()
    try repository.update { $0.directories[1].path = "/Movies/Nested" }
    #expect(throws: ConfigurationError.self) {
      _ = try repository.configurationAccessForIconChange(for: target, expectedConfiguration: before)
    }
  }

  /// A root access enforces current pause and exclusion state but permits explicit poster removal.
  @Test func configurationAccessForIconChangeEnforcesInclusionForPosterWrites() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = ConfigurationRepository(store: try PersistenceStore(directory: root))
    var configuration = CollectionProcessingConfiguration()
    let excluded = configuration.excludeFolder(identity: "child", lastKnownName: "Movie")
    #expect(excluded)
    let directory = MonitoredDirectory(
      id: UUID(), path: "/Movies", transferBookmark: Data([1]), authorizationVersion: UUID(),
      identity: "root", processingConfiguration: configuration)
    try repository.update { $0.directories = [directory] }
    let savedConfiguration = try repository.read()

    #expect(throws: ConfigurationError.folderExcluded) {
      _ = try repository.configurationAccessForIconChange(
        for: directory, childIdentity: "child", expectedConfiguration: savedConfiguration)
    }
    let removalAccess = try repository.configurationAccessForIconChange(
      for: directory, childIdentity: "child", requiresActiveCollection: false,
      expectedConfiguration: savedConfiguration)
    withExtendedLifetime(removalAccess) {}
  }

  /// Pause rejects normal root writes, and a stale inclusion generation rejects removal too.
  @Test func configurationAccessForIconChangeEnforcesPauseAndInclusionRevision() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = ConfigurationRepository(store: try PersistenceStore(directory: root))
    var configuration = CollectionProcessingConfiguration()
    let paused = configuration.setPaused(true)
    #expect(paused)
    let directory = MonitoredDirectory(
      id: UUID(), path: "/Movies", transferBookmark: Data([1]), authorizationVersion: UUID(),
      processingConfiguration: configuration)
    try repository.update { $0.directories = [directory] }
    let savedConfiguration = try repository.read()

    #expect(throws: ConfigurationError.collectionPaused) {
      _ = try repository.configurationAccessForIconChange(
        for: directory, expectedConfiguration: savedConfiguration)
    }
    var changedProcessingConfiguration = savedConfiguration.directories[0].processingConfiguration
    let unpaused = changedProcessingConfiguration.setPaused(false)
    #expect(unpaused)
    try repository.update { $0.directories[0].processingConfiguration = changedProcessingConfiguration }
    #expect(throws: ConfigurationError.configurationChanged) {
      _ = try repository.configurationAccessForIconChange(
        for: directory, requiresActiveCollection: false, expectedConfiguration: savedConfiguration)
    }
  }

  /// Verifies detects Nested Roots But Not Sibling Name Prefixes.
}

extension DirectoryConfigurationTests {
  @Test func detectsNestedRootsButNotSiblingNamePrefixes() {
    var configuration = DirectoryConfiguration()
    let parent = MonitoredDirectory(
      id: UUID(), path: "/Movies", transferBookmark: Data([1]),
      authorizationVersion: UUID())
    let child = MonitoredDirectory(
      id: UUID(), path: "/Movies/Action", transferBookmark: Data([2]),
      authorizationVersion: UUID())
    let sibling = MonitoredDirectory(
      id: UUID(), path: "/MoviesBackup", transferBookmark: Data([3]),
      authorizationVersion: UUID())
    configuration.directories = [parent, child, sibling]
    #expect(configuration.findOverlappingDirectoryIDs() == [parent.id, child.id])
  }

  /// Verifies detects Same Identity At Different Paths.
  @Test func detectsSameIdentityAtDifferentPaths() {
    var configuration = DirectoryConfiguration()
    let first = MonitoredDirectory(
      id: UUID(), path: "/Movies", transferBookmark: Data([1]),
      authorizationVersion: UUID(), identity: "same-object")
    let alias = MonitoredDirectory(
      id: UUID(), path: "/Alias", transferBookmark: Data([2]),
      authorizationVersion: UUID(), identity: "same-object")
    configuration.directories = [first, alias]
    #expect(configuration.findOverlappingDirectoryIDs() == [first.id, alias.id])
  }

  /// Verifies legacy Roots Decode Without Inventing Identity Evidence.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func legacyRootsDecodeWithoutInventingIdentityEvidence() throws {
    let rootID = UUID()
    let revision = UUID()
    let authorization = UUID()
    let json = """
      {"version":1,"directories":[{"id":"\(rootID)","path":"/Movies","transferBookmark":"AQ==",
      "authorizationVersion":"\(authorization)"}],"credentialRevision":"\(revision)",
      "developmentFixtures":false}
      """
    let configuration = try convertLegacySettingsFixture(Data(json.utf8))
    #expect(configuration.directories.first?.identity == .none)
    #expect(configuration.directories.first?.volumePath == .none)
    #expect(configuration.directories.first?.id == rootID)
    #expect(configuration.credentialRevision == revision)
  }

  /// Verifies appearance Migrates Old Settings Without Losing Authorization Or Credential Revision.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func appearanceMigratesOldSettingsWithoutLosingAuthorizationOrCredentialRevision() throws {
    var configuration = DirectoryConfiguration()
    configuration.directories = [
      MonitoredDirectory(
        id: UUID(), path: "/Movies", transferBookmark: Data([1, 2]),
        authorizationVersion: UUID())
    ]
    var old = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration))
        as? [String: Any])
    old.removeValue(forKey: "posterAppearance")
    old["version"] = 4
    let migrated = try convertLegacySettingsFixture(JSONSerialization.data(withJSONObject: old))
    #expect(migrated.posterAppearance == .softFinish)
    #expect(migrated.directories == configuration.directories)
    #expect(migrated.credentialRevision == configuration.credentialRevision)
    #expect(migrated.usesStubTMDbResponses == configuration.usesStubTMDbResponses)
  }

  /// Verifies appearance Persists Without Invalidating Movie Records.
  ///
  /// - Parameter appearance: The rendering finish selected for the assigned poster.
  /// - Throws: Errors from the underlying operation if its validation or required work cannot complete.
  @Test(arguments: PosterAppearance.allCases)
  func appearancePersistsWithoutInvalidatingMovieRecords(_ appearance: PosterAppearance) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = ConfigurationRepository(store: try PersistenceStore(directory: root))
    try repository.update { $0.directories = [] }
    let before = try repository.read()
    try repository.update { $0.posterAppearance = appearance }
    let reopened = try ConfigurationRepository(store: repository.store).read()
    #expect(reopened.posterAppearance == appearance)
    #expect(reopened.credentialRevision == before.credentialRevision)
  }

  /// Verifies holding Read Prevents Changes Until Change Finishes.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func holdingReadPreventsChangesUntilChangeFinishes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = ConfigurationRepository(store: try PersistenceStore(directory: root))
    try repository.update { $0.directories = [] }
    do {
      let (configuration, persistenceAccess) = try repository.readHoldingAccess()
      #expect(configuration.directories.isEmpty)
      #expect(throws: ConfigurationError.self) { try repository.update { $0.credentialRevision = UUID() } }
      withExtendedLifetime(persistenceAccess) {}
    }
    try repository.update { $0.credentialRevision = UUID() }
  }

  /// Verifies persists Directories Across Repository Instances.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func persistsDirectoriesAcrossRepositoryInstances() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try PersistenceStore(directory: root)
    let repository = ConfigurationRepository(store: store)
    let directory = MonitoredDirectory(
      id: UUID(), path: "/Movies", transferBookmark: Data([1]),
      authorizationVersion: UUID())
    try repository.update { $0.directories.append(directory) }
    #expect(try ConfigurationRepository(store: store).read().directories == [directory])
  }

  /// Verifies rejects Unsupported Version And Duplicate Identifiers.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func rejectsUnsupportedVersionAndDuplicateIdentifiers() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try PersistenceStore(directory: root)
    let repository = ConfigurationRepository(store: store)
    #expect(throws: ConfigurationError.self) { try repository.update { $0.version = 7 } }
    let directory = MonitoredDirectory(
      id: UUID(), path: "/Movies", transferBookmark: Data([1]),
      authorizationVersion: UUID())
    #expect(throws: ConfigurationError.self) {
      try repository.update { $0.directories = [directory, directory] }
    }
    #expect(try repository.read().directories.isEmpty)
  }

  /// Verifies reports Contention Instead Of Losing Updates.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func reportsContentionInsteadOfLosingUpdates() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try PersistenceStore(directory: root)
    let repository = ConfigurationRepository(store: store)
    let held = try #require(try store.acquireAccess(for: ConfigurationRepository.recordKey))
    #expect(throws: ConfigurationError.self) { try repository.update { $0.directories = [] } }
    withExtendedLifetime(held) {}
  }

  /// Verifies removing Directory Does Not Change Others Or Credential Revision.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func removingDirectoryDoesNotChangeOthersOrCredentialRevision() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = ConfigurationRepository(store: try PersistenceStore(directory: root))
    let first = MonitoredDirectory(
      id: UUID(), path: "/One", transferBookmark: Data([1]),
      authorizationVersion: UUID())
    let second = MonitoredDirectory(
      id: UUID(), path: "/Two", transferBookmark: Data([2]),
      authorizationVersion: UUID())
    try repository.update { $0.directories = [first, second] }
    let revision = try repository.read().credentialRevision
    try repository.update { $0.directories.removeAll { $0.id == first.id } }
    #expect(try repository.read().directories == [second])
    #expect(try repository.read().credentialRevision == revision)
  }
  /// Verifies credential Change Waits For Successful Persistence And Keeps Access.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func credentialChangeWaitsForSuccessfulPersistenceAndKeepsAccess() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try PersistenceStore(directory: root)
    let repository = ConfigurationRepository(store: store)
    var credentialMutated = false
    do {
      let held = try #require(try store.acquireAccess(for: ConfigurationRepository.recordKey))
      #expect(throws: ConfigurationError.self) {
        try repository.update({ $0.credentialRevision = UUID() }, afterCommit: { credentialMutated = true })
      }
      #expect(!credentialMutated)
      withExtendedLifetime(held) {}
    }
    let previous = try repository.read().credentialRevision
    try repository.update(
      { $0.credentialRevision = UUID() },
      afterCommit: {
        let competingAccess = try store.acquireAccess(for: ConfigurationRepository.recordKey)
        #expect(competingAccess == nil)
        credentialMutated = true
      })
    #expect(credentialMutated)
    #expect(try repository.read().credentialRevision != previous)
  }

  /// Verifies failed Persistence Does Not Run Credential Change.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func failedPersistenceDoesNotRunCredentialChange() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = ConfigurationRepository(store: try PersistenceStore(directory: root))
    try repository.update { $0.directories = [] }
    // A pinned descriptor survives renaming; removing its directory forces the next atomic write to fail.
    try FileManager.default.removeItem(at: root)
    var credentialMutated = false
    #expect(throws: (any Error).self) {
      try repository.update({ $0.credentialRevision = UUID() }, afterCommit: { credentialMutated = true })
    }
    #expect(!credentialMutated)
  }

  /// Verifies transient Read Contention Retries Without Dropping Configuration.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func transientReadContentionRetriesWithoutDroppingConfiguration() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try PersistenceStore(directory: root)
    let repository = ConfigurationRepository(store: store)
    let directory = MonitoredDirectory(
      id: UUID(), path: "/Configured", transferBookmark: Data([1]),
      authorizationVersion: UUID())
    try repository.update { $0.directories = [directory] }
    let gate: ConfigurationReadGate
    do {
      let held = try #require(try store.acquireAccess(for: ConfigurationRepository.recordKey))
      gate = ConfigurationReadGate(persistenceAccess: held)
    }
    let configuration = try await repository.readWhenAvailable(pause: { await gate.release() })
    #expect(configuration.directories == [directory])
    #expect(await gate.waitCount == 1)
  }

  /// Verifies persistent Contention Stops After Bounded Attempts.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func persistentContentionStopsAfterBoundedAttempts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try PersistenceStore(directory: root)
    let repository = ConfigurationRepository(store: store)
    let held = try #require(try store.acquireAccess(for: ConfigurationRepository.recordKey))
    let counter = ConfigurationReadGate(persistenceAccess: .none)
    do {
      _ = try await repository.readWhenAvailable(pause: { await counter.release() })
      Issue.record("Persistent contention must fail after bounded attempts")
    } catch ConfigurationError.busy {}
    #expect(await counter.waitCount == 7)
    withExtendedLifetime(held) {}
  }

}

/// Holds a real settings access until a retry test explicitly releases it.
private actor ConfigurationReadGate {
  /// The real persistence access retained until the contention test releases it.
  private var persistenceAccess: PersistenceAccess?
  /// The number of retry pauses observed while configuration was busy.
  private(set) var waitCount = Int.zero
  /// Creates the configuration read gate from the supplied dependencies and state.
  ///
  /// - Parameter persistenceAccess: The already-held persistence access used throughout this operation.
  init(persistenceAccess: PersistenceAccess?) { self.persistenceAccess = persistenceAccess }
  /// Releases the held continuation or access so the test can observe completion.
  func release() {
    waitCount += 1
    persistenceAccess = .none
  }
}
