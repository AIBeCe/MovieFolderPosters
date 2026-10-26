import Foundation
import MovieFolderCommon
import Testing

/// Verifiers on-disk field names and bytes while public Swift model names evolve.
struct PersistedModelNamingCompatibilityTests {
  /// Version-one settings retain their legacy fixture key and initialize the cache namespace on decode.
  /// - Throws: Fixture JSON encoding or configuration decoding errors.
  @Test func configurationRetainsLegacyFixtureFlagKeyAndBytes() throws {
    let legacy = try JSONSerialization.data(withJSONObject: [
      "version": 1,
      "directories": [],
      "credentialRevision": "11111111-1111-1111-1111-111111111111",
      "developmentFixtures": true,
      "posterAppearance": "softFinish"
    ], options: [.sortedKeys])
    let decoded = try convertLegacySettingsFixture(legacy)
    #expect(decoded.usesStubTMDbResponses)
    #expect(decoded.processingCacheRevision == decoded.credentialRevision)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let migrated = try encoder.encode(decoded)
    let migratedObject = try #require(JSONSerialization.jsonObject(with: migrated) as? [String: Any])
    #expect(migratedObject["version"] as? Int == 5)
    #expect(migratedObject["developmentFixtures"] as? Bool == true)
    #expect(migratedObject["processingCacheRevision"] as? String == "11111111-1111-1111-1111-111111111111")
  }

  /// Captured processing generations retain the original fixture flag key and all legacy context fields.
  /// - Throws: Fixture JSON encoding or processing-context decoding errors.
  @Test func processingContextRetainsLegacyFixtureFlagKeyAndBytes() throws {
    let legacy = try JSONSerialization.data(withJSONObject: [
      "rootID": "11111111-1111-1111-1111-111111111111",
      "rootIdentity": "root-identity",
      "authorizationVersion": "22222222-2222-2222-2222-222222222222",
      "credentialRevision": "33333333-3333-3333-3333-333333333333",
      "developmentFixtures": true,
      "appearance": "softFinish"
    ], options: [.sortedKeys])
    let decoded = try JSONDecoder().decode(CollectionProcessingContext.self, from: legacy)
    #expect(decoded.usesStubTMDbResponses)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    #expect(try encoder.encode(decoded) == legacy)
  }

  /// Renamed activity status preserves every legacy lifecycle value and the original event wire key.
  /// - Parameter rawStatus: A lifecycle value supported by the original persisted schema.
  /// - Throws: Fixture JSON encoding or activity-event decoding errors.
  @Test(arguments: ["started", "succeeded", "partial", "cancelled", "failed", "unavailable"])
  func activityStatusRetainsLegacyOutcomeKeyAndBytes(rawStatus: String) throws {
    let legacy = try JSONSerialization.data(withJSONObject: [
      "action": "automaticProcessing",
      "outcome": rawStatus,
      "operationID": "11111111-1111-1111-1111-111111111111",
      "collectionID": "22222222-2222-2222-2222-222222222222"
    ], options: [.sortedKeys])
    let decoded = try JSONDecoder().decode(MovieFolderActivityLogEvent.self, from: legacy)
    #expect(decoded.status.rawValue == rawStatus)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    #expect(try encoder.encode(decoded) == legacy)
  }

  /// Renaming the source key factory does not move existing version-one processing records.
  /// - Throws: A fixture identifier construction failure.
  @Test func processingStateKeyRetainsLegacyRecordPrefix() throws {
    let rootID = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
    #expect(CollectionProcessingStore.processingStateKey(for: rootID)
      == "processing-outcome-v1-11111111-1111-1111-1111-111111111111")
  }

  /// Events without opaque correlations retain the original omitted-field encoding.
  /// - Throws: Fixture JSON encoding or activity-event decoding errors.
  @Test func uncorrelatedActivityRetainsLegacyBytes() throws {
    let legacy = try JSONSerialization.data(withJSONObject: [
      "action": "applicationOpened", "outcome": "succeeded"
    ], options: [.sortedKeys])
    let decoded = try JSONDecoder().decode(MovieFolderActivityLogEvent.self, from: legacy)
    #expect(decoded.activityGroupID == .none)
    #expect(decoded.collectionID == .none)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    #expect(try encoder.encode(decoded) == legacy)
  }
  /// Descriptive Swift privacy names preserve the complete current JSON representation.
  /// - Throws: Configuration or fixture JSON encoding/decoding failures.
  @Test func privacyNamesRetainCurrentWireKeysAndBytes() throws {
    let persisted = try JSONSerialization.data(withJSONObject: [
      "version": 5,
      "directories": [[
        "id": "11111111-1111-1111-1111-111111111111",
        "path": "/Movies",
        "transferBookmark": "AQ==",
        "authorizationVersion": "22222222-2222-2222-2222-222222222222",
        "isPrivate": true,
        "participationPolicy": [
          "revision": "33333333-3333-3333-3333-333333333333",
          "isPaused": false,
          "excludedFolders": []
        ]
      ]],
      "credentialRevision": "44444444-4444-4444-4444-444444444444",
      "processingCacheRevision": "55555555-5555-5555-5555-555555555555",
      "retainsNetworkHistory": true,
      "historyRevision": "66666666-6666-6666-6666-666666666666",
      "developmentFixtures": false,
      "posterAppearance": "softFinish",
      "movieMatchingConfiguration": [
        "requiresReleaseYearForAutomaticMatching": false,
        "comparesOriginalTitles": true
      ]
    ], options: [.sortedKeys])
    let configuration = try JSONDecoder().decode(DirectoryConfiguration.self, from: persisted)
    #expect(configuration.isNetworkHistoryRecordingEnabled)
    #expect(configuration.directories.first?.usesPrivateHistory == true)
    #expect(configuration.networkHistoryConfigurationRevision.uuidString == "66666666-6666-6666-6666-666666666666")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    #expect(try encoder.encode(configuration) == persisted)
  }

}
