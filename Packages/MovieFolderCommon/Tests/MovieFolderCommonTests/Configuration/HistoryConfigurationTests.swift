import Foundation
import Persistence
import Testing

@testable import MovieFolderCommon

/// Privacy configuration has a separate generation from product processing.
struct HistoryConfigurationTests {
  /// Legacy records use stable defaults so different processes agree before a new commit.
  @Test func legacyDefaultsAreDeterministic() throws {
    let revision = UUID()
    let json = """
      {"version":1,"directories":[],"credentialRevision":"\(revision)","developmentFixtures":false}
      """
    let first = try convertLegacySettingsFixture(Data(json.utf8))
    let second = try convertLegacySettingsFixture(Data(json.utf8))
    #expect(!first.isNetworkHistoryRecordingEnabled)
    #expect(first.networkHistoryConfigurationRevision == revision)
    #expect(first.networkHistoryConfigurationRevision == second.networkHistoryConfigurationRevision)
  }

  /// Only history-relevant choices invalidate tickets, while every writer upgrades the schema.
  @Test func historyChangesRotateOnlyHistoryGeneration() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = ConfigurationRepository(store: try PersistenceStore(directory: directory))
    let root = MonitoredDirectory(id: UUID(), path: "/Movies", transferBookmark: Data([1]),
      authorizationVersion: UUID())
    try repository.update { $0.directories = [root] }
    let initial = try repository.read()
    try repository.update { $0.isNetworkHistoryRecordingEnabled = true }
    let enabled = try repository.read()
    #expect(enabled.version == 5)
    #expect(enabled.networkHistoryConfigurationRevision != initial.networkHistoryConfigurationRevision)
    #expect(enabled.credentialRevision == initial.credentialRevision)
    #expect(enabled.processingCacheRevision == initial.processingCacheRevision)
    try repository.update { $0.directories[0].usesPrivateHistory = true }
    let privateSettings = try repository.read()
    #expect(privateSettings.networkHistoryConfigurationRevision != enabled.networkHistoryConfigurationRevision)
    #expect(privateSettings.directories[0].processingConfiguration == root.processingConfiguration)
    #expect(privateSettings.directories[0].authorizationVersion == root.authorizationVersion)
    try repository.update { $0.directories[0].displayName = "Friendly" }
    #expect(try repository.read().networkHistoryConfigurationRevision
      == privateSettings.networkHistoryConfigurationRevision)
    try repository.updateCredential(expectedRevision: privateSettings.credentialRevision)
    #expect(try repository.read().version == 5)
    #expect(try repository.read().networkHistoryConfigurationRevision
      == privateSettings.networkHistoryConfigurationRevision)
  }
  /// Replacing a grant or root location fences requests prepared for the old root, even under the same UUID.
  @Test func rootReplacementRotatesHistoryRevision() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = ConfigurationRepository(store: try PersistenceStore(directory: directory))
    let root = MonitoredDirectory(id: UUID(), path: "/Movies", transferBookmark: Data([1]),
      authorizationVersion: UUID(), identity: "old-root")
    try repository.update { $0.directories = [root] }
    let before = try repository.read()
    try repository.update {
      $0.directories[0] = MonitoredDirectory(id: root.id, path: "/Replacement", transferBookmark: Data([2]),
        authorizationVersion: UUID(), identity: "new-root", processingConfiguration: root.processingConfiguration)
    }
    let after = try repository.read()
    #expect(after.networkHistoryConfigurationRevision != before.networkHistoryConfigurationRevision)
    #expect(after.credentialRevision == before.credentialRevision)
    #expect(after.processingCacheRevision == before.processingCacheRevision)
  }

  /// Normal readers reject retagged legacy data instead of resetting explicitly supplied privacy choices.
  @Test func normalReadersRequireExplicitMigrationForLegacyPrivacy() throws {
    var configuration = DirectoryConfiguration()
    configuration.isNetworkHistoryRecordingEnabled = true
    configuration.directories = [MonitoredDirectory(id: UUID(), path: "/Movies", transferBookmark: Data([1]),
      authorizationVersion: UUID(), usesPrivateHistory: true)]
    let current = try JSONEncoder().encode(configuration)
    for version in 1...4 {
      var object = try #require(JSONSerialization.jsonObject(with: current) as? [String: Any])
      object["version"] = version
      let encoded = try JSONSerialization.data(withJSONObject: object)
      #expect(throws: MovieFolderStorageMigrationError.migrationRequired(record: .settings, version: version)) {
        try JSONDecoder().decode(DirectoryConfiguration.self, from: encoded)
      }
    }
  }
}
