import Foundation
import Persistence
import Testing

@testable import MovieFolderCommon

/// Runs the explicit converter in memory for focused legacy-model fixtures; normal model readers never migrate.
func convertLegacySettingsFixture(_ payload: Data) throws -> DirectoryConfiguration {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let migrator = MovieFolderStorageMigrator(
    configurationStore: try PersistenceStore(directory: directory.appendingPathComponent("Settings")),
    collectionOutcomeStore: try PersistenceStore(directory: directory.appendingPathComponent("Outcomes")),
    backupStore: try PersistenceStore(directory: directory.appendingPathComponent("Backups")))

  return try migrator.convertSettings(payload).configuration
}

/// Converts a historical outcome fixture through the centralized raw-data converter before current-model decode.
func convertLegacyOutcomeFixture(_ payload: Data) throws -> CollectionProcessingState {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
  let context = try #require(object["context"] as? [String: Any])
  let rootID = try #require((context["rootID"] as? String).flatMap(UUID.init(uuidString:)))
  let migrator = MovieFolderStorageMigrator(
    configurationStore: try PersistenceStore(directory: directory.appendingPathComponent("Settings")),
    collectionOutcomeStore: try PersistenceStore(directory: directory.appendingPathComponent("Outcomes")),
    backupStore: try PersistenceStore(directory: directory.appendingPathComponent("Backups")))

  return try JSONDecoder().decode(CollectionProcessingState.self,
    from: migrator.convertOutcomes(payload, rootID: rootID).payload)
}
