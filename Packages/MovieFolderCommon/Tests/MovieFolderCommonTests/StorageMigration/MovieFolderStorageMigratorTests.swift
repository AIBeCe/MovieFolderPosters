import Foundation
import Persistence
import Testing

@testable import MovieFolderCommon

/// Isolated real Persistence namespaces exercise migration and backup ordering.
private struct MigrationFixture {
  /// Parent removed after each test.
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  /// Configured root retained across conversion.
  let root = MonitoredDirectory(id: UUID(), path: "/Movies", transferBookmark: Data([1]), authorizationVersion: UUID())
  /// Real source and backup stores.
  let settings: PersistenceStore
  let outcomes: PersistenceStore
  let backups: PersistenceStore
  /// Explicit migration service using the isolated namespaces.
  var migrator: MovieFolderStorageMigrator {
    MovieFolderStorageMigrator(configurationStore: settings, collectionOutcomeStore: outcomes, backupStore: backups)
  }

  /// Creates no saved records until a test explicitly writes a fixture.
  init() throws {
    settings = try PersistenceStore(directory: directory.appendingPathComponent("Settings"))
    outcomes = try PersistenceStore(directory: directory.appendingPathComponent("Outcomes"))
    backups = try PersistenceStore(directory: directory.appendingPathComponent("MigrationBackups"))
  }

  /// Writes current values using a legacy envelope and both historically renamed matching keys.
  func seed(settingsVersion: Int = 4, outcomeVersion: Int = 1) throws -> (Data, Data) {
    var configuration = DirectoryConfiguration()
    configuration.directories = [root]
    configuration.movieMatchingConfiguration.requiresReleaseYearForAutomaticMatching = true
    var settingsObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration))
      as? [String: Any])
    settingsObject["version"] = settingsVersion
    let matching = ["requiresReleaseYearForAutomaticIdentification": true, "comparesOriginalTitles": true]
    settingsObject.removeValue(forKey: "movieMatchingConfiguration")
    settingsObject["identificationPolicy"] = matching
    let settingsPayload = try JSONSerialization.data(withJSONObject: settingsObject, options: [.sortedKeys])
    try write(settingsPayload, to: settings, key: ConfigurationRepository.recordKey)
    let context = CollectionProcessingContext(rootID: root.id, rootIdentity: "root", authorizationVersion:
      root.authorizationVersion, credentialRevision: configuration.credentialRevision, usesStubTMDbResponses: false,
      appearance: .softFinish, movieMatchingConfiguration: configuration.movieMatchingConfiguration)
    let state = CollectionProcessingState(revision: 17, context: context,
      folders: [FolderProcessingRecord(name: "Movie", state: .preserved, reason: .existingPosterPreserved,
        movieID: 42, movieTitle: "Saved title", ownership: .unowned, fingerprint: "existing")],
      lastCompletedRunContext: context)
    var outcomeObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
    outcomeObject["schemaVersion"] = outcomeVersion
    for key in ["context", "lastCompletedRunContext"] {
      var savedContext = try #require(outcomeObject[key] as? [String: Any])
      savedContext["identificationPolicy"] = matching
      outcomeObject[key] = savedContext
    }
    let outcomePayload = try JSONSerialization.data(withJSONObject: outcomeObject, options: [.sortedKeys])
    try write(outcomePayload, to: outcomes, key: CollectionProcessingStore.processingStateKey(for: root.id))

    return (settingsPayload, outcomePayload)
  }

  /// Acquires one source access for a complete test fixture write.
  func write(_ payload: Data, to store: PersistenceStore, key: String) throws {
    let persistenceAccess = try #require(try store.acquireAccess(for: key))
    try persistenceAccess.write(payload)
  }

  /// Reads one source record under its real lease.
  func read(_ store: PersistenceStore, key: String) throws -> Data? {
    let persistenceAccess = try #require(try store.acquireAccess(for: key))

    return try persistenceAccess.read()
  }
}

/// Legacy data requires an explicit action, preserves facts and generations, and is independently backed up.
@Test func migrationConvertsSettingsAndBothOutcomeContextsWithoutLosingEvidence() throws {
  let fixture = try MigrationFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let (settingsPayload, outcomePayload) = try fixture.seed()
  #expect(try fixture.migrator.preflight().requiresMigration)
  #expect(throws: MovieFolderStorageMigrationError.migrationRequired(record: .settings, version: 4)) {
    try ConfigurationRepository(store: fixture.settings).read()
  }
  #expect(try fixture.read(fixture.settings, key: ConfigurationRepository.recordKey) == settingsPayload)
  let report = try fixture.migrator.migrate()
  #expect(report.migratedRecordCount == 2)
  let configuration = try ConfigurationRepository(store: fixture.settings).read()
  #expect(configuration.version == 5)
  #expect(configuration.movieMatchingConfiguration.requiresReleaseYearForAutomaticMatching)
  let statePayload = try #require(try fixture.read(fixture.outcomes,
    key: CollectionProcessingStore.processingStateKey(for: fixture.root.id)))
  let state = try JSONDecoder().decode(CollectionProcessingState.self, from: statePayload)
  #expect(state.schemaVersion == 2)
  #expect(state.revision == 17)
  #expect(state.folders.first?.movieTitle == "Saved title")
  #expect(state.folders.first?.ownership == .unowned)
  #expect(state.context.movieMatchingConfiguration.requiresReleaseYearForAutomaticMatching)
  #expect(state.lastCompletedRunContext?.movieMatchingConfiguration.requiresReleaseYearForAutomaticMatching == true)
  #expect(try fixture.migrator.migrate().skippedCurrentRecordCount == 2)
  #expect(!((try fixture.migrator.preflight()).requiresMigration))
  for (record, payload) in [(MovieFolderStorageRecordKind.settings, settingsPayload),
    (.collectionOutcomes(fixture.root.id), outcomePayload)] {
    #expect(try fixture.read(fixture.backups,
      key: MovieFolderStorageMigrator.backupRecordKey(for: record, originalPayload: payload)) == payload)
  }
}

/// Current settings must not hide a remaining old outcome after a partial migration.
@Test func currentSettingsWithLegacyOutcomeAreDetectedAndResumed() throws {
  let fixture = try MigrationFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  _ = try fixture.seed()
  do {
    let outcomeAccess = try #require(try fixture.outcomes.acquireAccess(
      for: CollectionProcessingStore.processingStateKey(for: fixture.root.id)))
    #expect(throws: MovieFolderStorageMigrationError.busy(record: .collectionOutcomes(fixture.root.id))) {
      try fixture.migrator.migrate()
    }
    withExtendedLifetime(outcomeAccess) {}
  }
  #expect(try ConfigurationRepository(store: fixture.settings).read().version == 5)
  let check = try fixture.migrator.preflight()
  #expect(!check.settingsRequiresMigration)
  #expect(check.legacyCollectionOutcomeRecordCount == 1)
  let resumed = try fixture.migrator.migrate()
  #expect(resumed.migratedRecordCount == 1)
  #expect(resumed.skippedCurrentRecordCount == 1)
}

/// A settings writer already holding the shared lease finishes before migration can establish the schema fence.
@Test func migrationWaitsForOlderSettingsWriterLease() throws {
  let fixture = try MigrationFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let (original, _) = try fixture.seed()
  do {
    let oldWriterAccess = try #require(try fixture.settings.acquireAccess(for: ConfigurationRepository.recordKey))
    #expect(throws: MovieFolderStorageMigrationError.busy(record: .settings)) { try fixture.migrator.migrate() }
    #expect(try oldWriterAccess.read() == original)
    try oldWriterAccess.write(original)
  }

  #expect(try fixture.migrator.migrate().migratedRecordCount == 2)
  #expect(try ConfigurationRepository(store: fixture.settings).read().version == 5)
}

/// Cancellation before the manual operation leaves all saved records byte-for-byte unchanged.
@Test func cancelledMigrationDoesNotWriteRecords() async throws {
  let fixture = try MigrationFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let (settings, outcomes) = try fixture.seed()
  let migration = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    return try fixture.migrator.migrate()
  }

  await #expect(throws: CancellationError.self) { try await migration.value }
  #expect(try fixture.read(fixture.settings, key: ConfigurationRepository.recordKey) == settings)
  #expect(try fixture.read(fixture.outcomes,
    key: CollectionProcessingStore.processingStateKey(for: fixture.root.id)) == outcomes)
}

/// Legacy defaults are applied only when the historical schema omitted those fields.
@Test func omittedLegacyFieldsReceiveHistoricalDefaults() throws {
  let fixture = try MigrationFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let (payload, _) = try fixture.seed(settingsVersion: 1)
  var object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
  object.removeValue(forKey: "processingCacheRevision")
  object.removeValue(forKey: "retainsNetworkHistory")
  object.removeValue(forKey: "historyRevision")
  object.removeValue(forKey: "posterAppearance")
  var roots = try #require(object["directories"] as? [[String: Any]])
  roots[0].removeValue(forKey: "isPrivate")
  roots[0].removeValue(forKey: "participationPolicy")
  object["directories"] = roots
  let legacy = try JSONSerialization.data(withJSONObject: object)
  try fixture.write(legacy, to: fixture.settings, key: ConfigurationRepository.recordKey)

  _ = try fixture.migrator.migrate()
  let configuration = try ConfigurationRepository(store: fixture.settings).read()
  #expect(configuration.processingCacheRevision == configuration.credentialRevision)
  #expect(!configuration.isNetworkHistoryRecordingEnabled)
  #expect(configuration.networkHistoryConfigurationRevision == configuration.credentialRevision)
  #expect(configuration.posterAppearance == .softFinish)
  #expect(!configuration.directories[0].usesPrivateHistory)
  #expect(!configuration.directories[0].processingConfiguration.isPaused)
  #expect(configuration.directories[0].processingConfiguration.excludedFolders.isEmpty)
}

/// All supported settings schemas preserve explicit privacy, history, and generation values.
@Test(arguments: [1, 2, 3, 4])
func legacySchemaMigrationPreservesExplicitPrivacyAndNestedOverrides(version: Int) throws {
  let fixture = try MigrationFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let (payload, _) = try fixture.seed(settingsVersion: version)
  var object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
  var roots = try #require(object["directories"] as? [[String: Any]])
  roots[0]["isPrivate"] = true
  roots[0]["identificationPolicy"] = ["requiresReleaseYearForAutomaticIdentification": true,
    "comparesOriginalTitles": false]
  object["directories"] = roots
  object["retainsNetworkHistory"] = true
  let historyRevision = UUID().uuidString
  object["historyRevision"] = historyRevision
  let credentialRevision = try #require(object["credentialRevision"] as? String)
  if version == 1 { object.removeValue(forKey: "processingCacheRevision") }
  try fixture.write(JSONSerialization.data(withJSONObject: object), to: fixture.settings,
    key: ConfigurationRepository.recordKey)
  _ = try fixture.migrator.migrate()
  let configuration = try ConfigurationRepository(store: fixture.settings).read()
  #expect(configuration.directories[0].usesPrivateHistory)
  #expect(configuration.isNetworkHistoryRecordingEnabled)
  #expect(configuration.networkHistoryConfigurationRevision.uuidString == historyRevision)
  #expect(configuration.credentialRevision.uuidString == credentialRevision)
  if version == 1 { #expect(configuration.processingCacheRevision == configuration.credentialRevision) }
  #expect(configuration.directories[0].movieMatchingConfiguration?.requiresReleaseYearForAutomaticMatching == true)
  #expect(configuration.directories[0].movieMatchingConfiguration?.comparesOriginalTitles == false)
}

/// A conflict does not select a favorite alias or change the source payload.
@Test func conflictingMatchingAliasesPreserveOriginalSettings() throws {
  let fixture = try MigrationFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let (payload, _) = try fixture.seed()
  var object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
  object["movieMatchingConfiguration"] = ["requiresReleaseYearForAutomaticMatching": false,
    "comparesOriginalTitles": true]
  let original = try JSONSerialization.data(withJSONObject: object)
  try fixture.write(original, to: fixture.settings, key: ConfigurationRepository.recordKey)
  #expect(throws: MovieFolderStorageMigrationError.conflictingValues(record: .settings,
    field: "movieMatchingConfiguration")) { try fixture.migrator.migrate() }
  #expect(try fixture.read(fixture.settings, key: ConfigurationRepository.recordKey) == original)
}

/// Backup contention and an existing conflicting backup prevent any corresponding source replacement.
@Test func backupFailurePreventsSettingsReplacementAndNeverOverwritesBackup() throws {
  let fixture = try MigrationFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let (original, _) = try fixture.seed()
  let key = MovieFolderStorageMigrator.backupRecordKey(for: .settings, originalPayload: original)
  do {
    let backupAccess = try #require(try fixture.backups.acquireAccess(for: key))
    #expect(throws: MovieFolderStorageMigrationError.backupUnavailable(record: .settings)) {
      try fixture.migrator.migrate()
    }
    #expect(try fixture.read(fixture.settings, key: ConfigurationRepository.recordKey) == original)
    try backupAccess.write(Data("different backup".utf8))
  }
  #expect(throws: MovieFolderStorageMigrationError.backupConflict(record: .settings)) {
    try fixture.migrator.migrate()
  }
  #expect(try fixture.read(fixture.settings, key: ConfigurationRepository.recordKey) == original)
  #expect(try fixture.read(fixture.backups, key: key) == Data("different backup".utf8))
}

/// Future versions are never guessed at or rewritten by preflight, migration, or normal readers.
@Test func futureSettingsSchemaIsRejectedWithoutChangingBytes() throws {
  let fixture = try MigrationFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let (original, _) = try fixture.seed(settingsVersion: 6)
  #expect(throws: MovieFolderStorageMigrationError.unsupportedVersion(record: .settings, version: 6)) {
    try fixture.migrator.preflight()
  }
  #expect(throws: MovieFolderStorageMigrationError.unsupportedVersion(record: .settings, version: 6)) {
    try fixture.migrator.migrate()
  }
  #expect(throws: MovieFolderStorageMigrationError.unsupportedVersion(record: .settings, version: 6)) {
    try ConfigurationRepository(store: fixture.settings).read()
  }
  #expect(try fixture.read(fixture.settings, key: ConfigurationRepository.recordKey) == original)
}

/// Normal readers preserve old outcomes and report the migration action before decoding renamed context fields.
@Test func normalOutcomeReaderRequiresMigrationWithoutWritingLegacyData() throws {
  let fixture = try MigrationFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let (_, original) = try fixture.seed()
  let store = CollectionProcessingStore(store: fixture.outcomes,
    configuration: ConfigurationRepository(store: fixture.settings))
  #expect(throws: MovieFolderStorageMigrationError.migrationRequired(
    record: .collectionOutcomes(fixture.root.id), version: 1)) { try store.read(rootID: fixture.root.id) }
  #expect(try fixture.read(fixture.outcomes,
    key: CollectionProcessingStore.processingStateKey(for: fixture.root.id)) == original)
}

/// Each outcome replacement depends on its own verified backup, independently of the earlier settings fence.
@Test func outcomeBackupFailureLeavesFenceAndResumesWithoutReplacingSource() throws {
  let fixture = try MigrationFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let (_, original) = try fixture.seed()
  let record = MovieFolderStorageRecordKind.collectionOutcomes(fixture.root.id)
  let backupKey = MovieFolderStorageMigrator.backupRecordKey(for: record, originalPayload: original)
  do {
    let backupAccess = try #require(try fixture.backups.acquireAccess(for: backupKey))
    #expect(throws: MovieFolderStorageMigrationError.backupUnavailable(record: record)) {
      try fixture.migrator.migrate()
    }
    #expect(try ConfigurationRepository(store: fixture.settings).read().version == 5)
    #expect(try fixture.read(fixture.outcomes,
      key: CollectionProcessingStore.processingStateKey(for: fixture.root.id)) == original)
    withExtendedLifetime(backupAccess) {}
  }
  #expect(try fixture.migrator.migrate().migratedRecordCount == 1)
}

/// Invalid current payloads receive repair-oriented errors instead of being confused with unavailable volumes.
@Test func malformedCurrentRecordErrorsRemainSpecificAndReadOnly() throws {
  let fixture = try MigrationFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let invalidSettings = Data("{\"version\":5}".utf8)
  try fixture.write(invalidSettings, to: fixture.settings, key: ConfigurationRepository.recordKey)
  #expect(throws: MovieFolderStorageMigrationError.invalidRecord(record: .settings)) {
    try ConfigurationRepository(store: fixture.settings).read()
  }
  let invalidOutcomes = Data("{\"schemaVersion\":2}".utf8)
  try fixture.write(invalidOutcomes, to: fixture.outcomes,
    key: CollectionProcessingStore.processingStateKey(for: fixture.root.id))
  let store = CollectionProcessingStore(store: fixture.outcomes,
    configuration: ConfigurationRepository(store: fixture.settings))
  #expect(throws: MovieFolderStorageMigrationError.invalidRecord(record: .collectionOutcomes(fixture.root.id))) {
    try store.read(rootID: fixture.root.id)
  }
  #expect(try fixture.read(fixture.settings, key: ConfigurationRepository.recordKey) == invalidSettings)
  #expect(try fixture.read(fixture.outcomes,
    key: CollectionProcessingStore.processingStateKey(for: fixture.root.id)) == invalidOutcomes)
}
