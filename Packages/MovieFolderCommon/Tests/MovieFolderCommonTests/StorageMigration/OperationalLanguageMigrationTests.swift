import Foundation
import Network
import Persistence
import Testing
@testable import MovieFolderCommon

/// Real app-owned namespaces provide exact-backup and operational lock evidence without opening movie roots.
private struct OperationalMigrationFixture {
  /// Temporary app container, removed after each test.
  let container: URL
  /// Stable collection context deliberately pointing at an absent movie root.
  let root: MonitoredDirectory
  /// Current processing namespace generation, preserved during migration.
  let configuration: DirectoryConfiguration
  /// Source settings namespace.
  let settings: PersistenceStore
  /// Source authoritative outcomes namespace.
  let outcomes: PersistenceStore
  /// Source operational decisions namespace.
  let operational: PersistenceStore
  /// Original-byte recovery copies.
  let backups: PersistenceStore
  /// Same root coordination namespace used by processors.
  let locks: PersistenceStore
  /// Explicitly composed migration service.
  var migrator: MovieFolderStorageMigrator {
    MovieFolderStorageMigrator(configurationStore: settings, collectionOutcomeStore: outcomes, backupStore: backups,
      operationalContainer: container, coordinationStore: locks)
  }
  /// Exact processing key derived from the authorized saved canonical path without filesystem resolution.
  var operationalKey: String { "movie-folder-processing:" + root.path }

  /// Creates current stores and one supported legacy payload for each of the three record kinds.
  init() throws {
    container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    root = MonitoredDirectory(id: UUID(), path: "/AbsentMovieRoot", transferBookmark: Data([1]),
      authorizationVersion: UUID())
    var configuration = DirectoryConfiguration()
    configuration.directories = [root]
    self.configuration = configuration
    settings = try PersistenceStore(directory: container.appendingPathComponent("Settings"))
    outcomes = try PersistenceStore(directory: container.appendingPathComponent("Outcomes"))
    operational = try PersistenceStore(directory: container.appendingPathComponent(
      "Processing/\(configuration.processingCacheRevision)"))
    backups = try PersistenceStore(directory: container.appendingPathComponent("Backups"))
    locks = try PersistenceStore(directory: container.appendingPathComponent("ProcessingLocks"))
  }

  /// Saves supported old formats, preserving exact source bytes for assertions.
  func seed() throws -> [(MovieFolderStorageRecordKind, Data)] {
    var settingsObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration))
      as? [String: Any])
    settingsObject["version"] = 5
    var matching = try #require(settingsObject["movieMatchingConfiguration"] as? [String: Any])
    matching.removeValue(forKey: "searchLanguage")
    settingsObject["movieMatchingConfiguration"] = matching
    let settingsPayload = try JSONSerialization.data(withJSONObject: settingsObject)
    try write(settingsPayload, store: settings, key: ConfigurationRepository.recordKey)
    let context = CollectionProcessingContext(rootID: root.id, rootIdentity: "root",
      authorizationVersion: root.authorizationVersion, credentialRevision: configuration.credentialRevision,
      usesStubTMDbResponses: false, appearance: .softFinish)
    var outcomesObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(
      CollectionProcessingState(revision: 17, context: context, lastCompletedRunContext: context))) as? [String: Any])
    outcomesObject["schemaVersion"] = 2
    for key in ["context", "lastCompletedRunContext"] {
      var stored = try #require(outcomesObject[key] as? [String: Any])
      stored["identificationPolicy"] = matching
      outcomesObject[key] = stored
    }
    let outcomePayload = try JSONSerialization.data(withJSONObject: outcomesObject)
    try write(outcomePayload, store: outcomes, key: CollectionProcessingStore.processingStateKey(for: root.id))
    var state = ProcessingState(folders: ["Alien": FolderRecord(fingerprint: "original", status: .processed,
      retryDate: Date(timeIntervalSince1970: 1234), matchedMovieID: 42, posterPath: "/alien.jpg",
      movieTitle: "Alien", movieYear: 1979, movieIdentitySource: .explicitSelection)],
      providerRetryAt: Date(timeIntervalSince1970: 5678), credentialRevision: configuration.credentialRevision)
    state.folders["Alien"]?.requiresAutomaticReassessment = true
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
    object.removeValue(forKey: "schemaVersion")
    object.removeValue(forKey: "alternativeTitles")
    object["movieMatchingConfiguration"] = matching
    object["queries"] = ["unsafe-context-free": ["ignored": true]]
    let operationalPayload = try JSONSerialization.data(withJSONObject: object)
    try write(operationalPayload, store: operational, key: operationalKey)

    return [(.settings, settingsPayload), (.collectionOutcomes(root.id), outcomePayload),
      (.operationalProcessing(root.id), operationalPayload)]
  }

  /// Writes one record through the real nonwaiting persistence lease.
  func write(_ payload: Data, store: PersistenceStore, key: String) throws {
    let access = try #require(try store.acquireAccess(for: key))
    try access.write(payload)
  }

  /// Reads one record through the real nonwaiting persistence lease.
  func read(_ store: PersistenceStore, key: String) throws -> Data? {
    let access = try #require(try store.acquireAccess(for: key))

    return try access.read()
  }
}

/// All three formats are backed up and converted while operational identities, retries and namespace stay intact.
@Test func migrationPreservesOperationalIdentityAndAllThreeOriginals() throws {
  let fixture = try OperationalMigrationFixture()
  defer { try? FileManager.default.removeItem(at: fixture.container) }
  let originals = try fixture.seed()
  let preflight = try fixture.migrator.preflight()
  #expect(preflight.settingsRequiresMigration)
  #expect(preflight.legacyCollectionOutcomeRecordCount == 1)
  #expect(preflight.legacyOperationalRecordCount == 1)
  #expect(try fixture.migrator.migrate().migratedRecordCount == 3)
  let current = try ConfigurationRepository(store: fixture.settings).read()
  #expect(current.processingCacheRevision == fixture.configuration.processingCacheRevision)
  #expect(current.movieMatchingConfiguration.searchLanguage == .english)
  #expect(current.directories.first?.movieMatchingConfiguration == .none)
  let payload = try #require(try fixture.read(fixture.operational, key: fixture.operationalKey))
  let state = try JSONDecoder().decode(ProcessingState.self, from: payload)
  #expect(state.folders["Alien"]?.matchedMovieID == 42)
  #expect(state.folders["Alien"]?.posterPath == "/alien.jpg")
  #expect(state.folders["Alien"]?.movieIdentitySource == .explicitSelection)
  #expect(state.folders["Alien"]?.requiresAutomaticReassessment == true)
  #expect(state.folders["Alien"]?.retryDate == Date(timeIntervalSince1970: 1234))
  #expect(state.providerRetryAt == Date(timeIntervalSince1970: 5678))
  #expect(state.credentialRevision == current.credentialRevision)
  #expect(state.queries.isEmpty)
  for (kind, original) in originals {
    #expect(try fixture.read(fixture.backups,
      key: MovieFolderStorageMigrator.backupRecordKey(for: kind, originalPayload: original)) == original)
  }
  #expect(try fixture.migrator.migrate().skippedCurrentRecordCount == 3)
  #expect(!(try fixture.migrator.preflight().requiresMigration))
}

/// A running processor prevents operational conversion, then a retry resumes already committed earlier records.
@Test func migrationHonorsOperationalCoordinationAndResumes() throws {
  let fixture = try OperationalMigrationFixture()
  defer { try? FileManager.default.removeItem(at: fixture.container) }
  _ = try fixture.seed()
  do {
    let held = try #require(try fixture.locks.acquireAccess(for: "movie-folder-coordination:" + fixture.root.path))
    #expect(throws: MovieFolderStorageMigrationError.busy(record: .operationalProcessing(fixture.root.id))) {
      try fixture.migrator.migrate()
    }
    withExtendedLifetime(held) {}
  }
  let report = try fixture.migrator.migrate()
  #expect(report.migratedRecordCount == 1)
  #expect(report.skippedCurrentRecordCount == 2)
}

/// Current readers refuse absent language and old operational formats instead of automatically upgrading them.
@Test func currentReadersRejectMissingLanguageAndUnversionedOperationalState() throws {
  let fixture = try OperationalMigrationFixture()
  defer { try? FileManager.default.removeItem(at: fixture.container) }
  let originals = try fixture.seed()
  let original = try #require(originals.last?.1)
  #expect(throws: (any Error).self) { try JSONDecoder().decode(ProcessingState.self, from: original) }
  let invalid = Data("{\"requiresReleaseYearForAutomaticMatching\":false,\"comparesOriginalTitles\":true}".utf8)
  #expect(throws: (any Error).self) { try JSONDecoder().decode(MovieMatchingConfiguration.self, from: invalid) }
  var current = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.configuration))
    as? [String: Any])
  current["movieMatchingConfiguration"] = try JSONSerialization.jsonObject(with: invalid)
  #expect(throws: MovieFolderStorageMigrationError.invalidRecord(record: .settings)) {
    try fixture.migrator.convertSettings(JSONSerialization.data(withJSONObject: current))
  }
}
