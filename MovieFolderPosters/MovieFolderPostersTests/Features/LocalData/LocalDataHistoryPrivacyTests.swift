import FileSystem
import Foundation
import MovieFolderCommon
import Persistence
import Testing

@testable import MovieFolderPosters

struct LocalDataHistoryPrivacyTests {
  @Test func absentSavedSettingsHaveStablePrivacyAndRemainAbsent() throws {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    let repository = ConfigurationRepository(store: try PersistenceStore(directory: root))
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try LocalDataExportService.historyPrivacyFingerprint(in: repository)
    let second = try LocalDataExportService.historyPrivacyFingerprint(in: repository)
    #expect(first == second)
    let (configuration, access) = try repository.readIfPresentHoldingAccess()
    withExtendedLifetime(access) { #expect(configuration == nil) }
  }

  @Test func irrelevantPosterSettingsPreservePrivacyButRetentionChangesInvalidateIt() throws {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    let repository = ConfigurationRepository(store: try PersistenceStore(directory: root))
    defer { try? FileManager.default.removeItem(at: root) }
    try repository.update { $0.posterAppearance = .raw }
    let first = try LocalDataExportService.historyPrivacyFingerprint(in: repository)
    try repository.update { $0.posterAppearance = .matteFrame }
    #expect(try LocalDataExportService.historyPrivacyFingerprint(in: repository) == first)
    try repository.update { $0.isNetworkHistoryRecordingEnabled = true }
    #expect(try LocalDataExportService.historyPrivacyFingerprint(in: repository) != first)
  }

  @Test func busyAndCorruptSettingsRemainUnavailableInsteadOfAbsent() throws {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    let store = try PersistenceStore(directory: root)
    let repository = ConfigurationRepository(store: store)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
      let access = try #require(try store.acquireAccess(for: ConfigurationRepository.recordKey))
      try withExtendedLifetime(access) {
        #expect((try? LocalDataExportService.historyPrivacyFingerprint(in: repository)) == nil)
        try access.write(Data("Malformed configuration".utf8))
      }
    }
    #expect((try? LocalDataExportService.historyPrivacyFingerprint(in: repository)) == nil)
  }
}
