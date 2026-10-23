import FileSystem
import Foundation
import Network
import Persistence
import Testing

@testable import MovieFolderCommon

/// Names and identification choices must survive persistence without weakening processing fencing.
struct CollectionSetupPolicyTests {
  /// Names are trimmed, bounded, and independent of filesystem identity.
  @Test func displayNamesAreNormalizedAndPersisted() throws {
    var root = MonitoredDirectory(id: UUID(), path: "/Volumes/Movies", transferBookmark: Data([1]),
      authorizationVersion: UUID(), displayName: "  Family films \n")
    #expect(root.effectiveDisplayName == "Family films")
    root = try JSONDecoder().decode(MonitoredDirectory.self, from: JSONEncoder().encode(root))
    #expect(root.displayName == "Family films")
    root.path = "/Volumes/Relocated"
    #expect(root.effectiveDisplayName == "Family films")
    #expect(MonitoredDirectory.normalizedDisplayName(" \n") == .none)
    #expect(MonitoredDirectory.normalizedDisplayName(String(repeating: "x", count: 121))?.count == 120)
  }

  /// Defaults migrate old records while explicit collection overrides remain snapshots.
  @Test func policyInheritanceAndLegacyDecoding() throws {
    var configuration = DirectoryConfiguration()
    let root = MonitoredDirectory(id: UUID(), path: "/Movies", transferBookmark: Data([1]),
      authorizationVersion: UUID())
    configuration.directories = [root]
    var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration))
      as? [String: Any])
    fields.removeValue(forKey: "identificationPolicy")
    let old = try JSONDecoder().decode(DirectoryConfiguration.self,
      from: JSONSerialization.data(withJSONObject: fields))
    #expect(old.identificationPolicy == IdentificationPolicy())
    configuration.identificationPolicy.comparesOriginalTitles = false
    #expect(!configuration.effectiveIdentificationPolicy(for: root).comparesOriginalTitles)
    var overridden = root
    overridden.identificationPolicy = IdentificationPolicy()
    #expect(configuration.effectiveIdentificationPolicy(for: overridden).comparesOriginalTitles)
  }

  /// Renaming is presentation-only; changing effective identification must invalidate a captured mutation.
  @Test func mutationFencesPolicyButNotName() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = ConfigurationRepository(store: try PersistenceStore(directory: directory))
    let root = MonitoredDirectory(id: UUID(), path: "/Movies", transferBookmark: Data([1]),
      authorizationVersion: UUID())
    try repository.update { $0.directories = [root] }
    let before = try repository.read()
    try repository.update { $0.directories[0].displayName = "Films" }
    do { let lease = try repository.mutationLease(for: root, expectedConfiguration: before)
      withExtendedLifetime(lease) {} }
    try repository.update { $0.identificationPolicy.comparesOriginalTitles = false }
    #expect(throws: ConfigurationError.self) {
      _ = try repository.mutationLease(for: root, expectedConfiguration: before)
    }
  }
}
