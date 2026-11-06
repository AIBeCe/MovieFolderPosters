import Foundation
import Persistence
import Testing
@testable import MovieFolderCommon

/// Optional local sources are independent, opt-in choices preserved by current storage.
@Test func localInformationConfigurationDefaultsAndRoundTrips() throws {
  let defaults = MovieMatchingConfiguration()
  #expect(!defaults.readsNFOInformation)
  #expect(!defaults.readsImmediateVideoNames)
  #expect(!defaults.readsImmediateImageNames)
  for bits in 0..<8 {
    var configuration = DirectoryConfiguration()
    configuration.movieMatchingConfiguration.readsNFOInformation = bits & 1 != 0
    configuration.movieMatchingConfiguration.readsImmediateVideoNames = bits & 2 != 0
    configuration.movieMatchingConfiguration.readsImmediateImageNames = bits & 4 != 0
    configuration.directories = [MonitoredDirectory(id: UUID(), path: "/AbsentCollection",
      transferBookmark: Data([1]), authorizationVersion: UUID(),
      movieMatchingConfiguration: configuration.movieMatchingConfiguration)]
    let decoded = try JSONDecoder().decode(DirectoryConfiguration.self, from: JSONEncoder().encode(configuration))
    #expect(decoded == configuration)
  }
}

/// Both live and historical outcomes and prior versioned operational records preserve their facts on migration.
@Test func localInformationConfigurationMigratesEmbeddedContextsAndCache() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let migrator = MovieFolderStorageMigrator(
    configurationStore: try PersistenceStore(directory: directory.appendingPathComponent("settings")),
    collectionOutcomeStore: try PersistenceStore(directory: directory.appendingPathComponent("outcomes")),
    backupStore: try PersistenceStore(directory: directory.appendingPathComponent("backups")))
  let context = CollectionProcessingContext(rootID: UUID(), rootIdentity: "root",
    authorizationVersion: UUID(), credentialRevision: UUID(), usesStubTMDbResponses: false, appearance: .softFinish)
  let state = CollectionProcessingState(revision: 17, context: context, lastCompletedRunContext: context)
  var outcome = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
  outcome["schemaVersion"] = 3
  for key in ["context", "lastCompletedRunContext"] {
    var embedded = try #require(outcome[key] as? [String: Any])
    embedded["identificationPolicy"] = try previousMatchingFields(embedded["identificationPolicy"])
    outcome[key] = embedded
  }
  let converted = try migrator.convertOutcomes(JSONSerialization.data(withJSONObject: outcome), rootID: context.rootID)
  let decoded = try JSONDecoder().decode(CollectionProcessingState.self, from: converted.payload)
  #expect(converted.wasLegacy)
  #expect(decoded == state)
  let cache = CollectionProcessingCache(folders: ["Alien": FolderProcessingCacheRecord(fingerprint: "same",
    status: .processed, retryDate: .none, matchedMovieID: 348, posterPath: "/alien.jpg",
    movieIdentitySource: .explicitSelection)])
  var operational = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(cache)) as? [String: Any])
  operational["schemaVersion"] = 1
  operational["movieMatchingConfiguration"] = try previousMatchingFields(operational["movieMatchingConfiguration"])
  let migrated = try migrator.convertOperational(JSONSerialization.data(withJSONObject: operational),
    rootID: context.rootID)
  let decodedCache = try JSONDecoder().decode(CollectionProcessingCache.self, from: migrated.payload)
  #expect(migrated.wasLegacy)
  let encoder = JSONEncoder()
  encoder.outputFormatting = .sortedKeys
  #expect(try encoder.encode(decodedCache.folders) == encoder.encode(cache.folders))
  #expect(decodedCache.movieMatchingConfiguration == cache.movieMatchingConfiguration)
}

/// Removes only newly introduced fields to recreate an otherwise valid preceding matching representation.
private func previousMatchingFields(_ object: Any?) throws -> [String: Any] {
  var matching = try #require(object as? [String: Any])
  for field in ["readsNFOInformation", "readsImmediateVideoNames", "readsImmediateImageNames"] {
    matching.removeValue(forKey: field)
  }

  return matching
}

/// Source settings invalidate automatic assessments rather than being mistaken for a language-only change.
@Test func localInformationConfigurationInvalidatesAutomaticAssessmentsOnly() {
  let automatic = FolderProcessingCacheRecord(fingerprint: "same", status: .processed, retryDate: .none,
    matchedMovieID: 348, posterPath: "/alien.jpg", movieIdentitySource: .conservativeMatch)
  var explicit = automatic
  explicit.movieIdentitySource = .explicitSelection
  var cache = CollectionProcessingCache(folders: ["automatic": automatic, "explicit": explicit])
  var configuration = MovieMatchingConfiguration()
  configuration.readsImmediateImageNames = true
  cache.updateMatchingConfiguration(configuration)
  #expect(cache.folders["automatic"]?.requiresAutomaticReview == true)
  #expect(cache.folders["explicit"]?.movieIdentitySource == explicit.movieIdentitySource)
  #expect(cache.folders["explicit"]?.matchedMovieID == explicit.matchedMovieID)
  #expect(cache.folders["explicit"]?.requiresAutomaticReview == explicit.requiresAutomaticReview)
}

/// Prior schema settings require explicit migration; generations and prior choices remain intact.
@Test func localInformationConfigurationMigratesPreviousSettings() throws {
  var current = DirectoryConfiguration()
  current.movieMatchingConfiguration.comparesOriginalTitles = false
  var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
  object["version"] = 7
  var matching = try #require(object["movieMatchingConfiguration"] as? [String: Any])
  for key in ["readsNFOInformation", "readsImmediateVideoNames", "readsImmediateImageNames"] {
    matching.removeValue(forKey: key)
  }
  object["movieMatchingConfiguration"] = matching
  let payload = try JSONSerialization.data(withJSONObject: object)
  #expect(throws: MovieFolderStorageMigrationError.migrationRequired(record: .settings, version: 7)) {
    try JSONDecoder().decode(DirectoryConfiguration.self, from: payload)
  }
  #expect(try convertLegacySettingsFixture(payload) == current)
}

/// Recent historical schemas must not manufacture privacy or inclusion values they already required.
@Test(arguments: [6, 7], ["isPrivate", "participationPolicy"])
func localInformationMigrationRejectsMissingRequiredCollectionFields(version: Int, field: String) throws {
  var configuration = DirectoryConfiguration()
  configuration.directories = [MonitoredDirectory(id: UUID(), path: "/AbsentCollection",
    transferBookmark: Data([1]), authorizationVersion: UUID())]
  var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
  object["version"] = version
  if version == 6 { object.removeValue(forKey: "searchPageLimit") }
  var directories = try #require(object["directories"] as? [[String: Any]])
  directories[0].removeValue(forKey: field)
  object["directories"] = directories
  let payload = try JSONSerialization.data(withJSONObject: object)
  #expect(throws: MovieFolderStorageMigrationError.invalidRecord(record: .settings)) {
    try convertLegacySettingsFixture(payload)
  }
}

/// Current data cannot silently select defaults when required source settings are missing.
@Test(arguments: ["readsNFOInformation", "readsImmediateVideoNames", "readsImmediateImageNames"])
func localInformationConfigurationRequiresCurrentFields(key: String) throws {
  var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(MovieMatchingConfiguration()))
    as? [String: Any])
  object.removeValue(forKey: key)
  let payload = try JSONSerialization.data(withJSONObject: object)
  #expect(throws: (any Error).self) { try JSONDecoder().decode(MovieMatchingConfiguration.self, from: payload) }
}
