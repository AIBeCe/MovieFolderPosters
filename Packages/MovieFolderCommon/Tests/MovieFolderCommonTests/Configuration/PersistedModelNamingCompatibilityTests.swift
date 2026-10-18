import Foundation
import MovieFolderCommon
import Testing

/// Guards on-disk field names and bytes while public Swift model names evolve.
struct PersistedModelNamingCompatibilityTests {
  /// Renamed configuration flags retain the original version-one JSON key and canonical bytes.
  /// - Throws: Fixture JSON encoding or configuration decoding errors.
  @Test func configurationRetainsLegacyFixtureFlagKeyAndBytes() throws {
    let legacy = try JSONSerialization.data(withJSONObject: [
      "version": 1,
      "directories": [],
      "credentialRevision": "11111111-1111-1111-1111-111111111111",
      "developmentFixtures": true,
      "posterAppearance": "softFinish"
    ], options: [.sortedKeys])
    let decoded = try JSONDecoder().decode(DirectoryConfiguration.self, from: legacy)
    #expect(decoded.usesStubTMDbResponses)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    #expect(try encoder.encode(decoded) == legacy)
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
    let decoded = try JSONDecoder().decode(MovieFolderActivityEvent.self, from: legacy)
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
    let decoded = try JSONDecoder().decode(MovieFolderActivityEvent.self, from: legacy)
    #expect(decoded.operationID == nil)
    #expect(decoded.collectionID == nil)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    #expect(try encoder.encode(decoded) == legacy)
  }
}
