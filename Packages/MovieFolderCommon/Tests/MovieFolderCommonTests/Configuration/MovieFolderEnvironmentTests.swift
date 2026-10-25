import Foundation
import Testing

@testable import MovieFolderCommon

/// Factories must use the injected locations without opening the real signed App Group.
struct MovieFolderEnvironmentTests {
  /// Settings, collection outcomes, and authorization remain in distinct persistence namespaces.
  @Test func factoriesReopenOnlyTheSuppliedDirectories() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let locations = TestStorageLocations(root: root)
    let repository = try MovieFolderEnvironment.makeConfigurationRepository(locations: locations)
    try repository.update { $0.usesStubTMDbResponses = true }
    let reopened = try MovieFolderEnvironment.makeConfigurationRepository(locations: locations)
    #expect(try reopened.read().usesStubTMDbResponses)
    _ = try MovieFolderEnvironment.makeCollectionProcessingStore(locations: locations)
    _ = try MovieFolderEnvironment.makePrivateAuthorizationStore(locations: locations)
    let recovery = try MovieFolderEnvironment.makeProcessingRecoveryService(locations: locations)
    try recovery.setRecoveryModeEnabled(true)
    let reopenedRecovery = try MovieFolderEnvironment.makeProcessingRecoveryService(locations: locations)
    #expect(try reopenedRecovery.read().isRecoveryModeEnabled)
    #expect(try reopened.read().usesStubTMDbResponses)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("ProcessingRecovery").path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Settings").path))
    let authorization = root.appendingPathComponent("MovieFolderPosters/Authorization")
    #expect(FileManager.default.fileExists(atPath: authorization.path))
  }

  /// Activity startup failure stays best effort while explicit settings access reports failure.
  @Test func missingContainerIsExplicitForSettingsAndUnavailableForActivity() async throws {
    let locations = TestStorageLocations(root: .none)
    #expect(throws: ConfigurationError.self) {
      try MovieFolderEnvironment.makeConfigurationRepository(locations: locations)
    }
    #expect(throws: ConfigurationError.self) {
      try MovieFolderEnvironment.makeCollectionProcessingStore(locations: locations)
    }
    #expect(throws: ConfigurationError.self) {
      try MovieFolderEnvironment.makePrivateAuthorizationStore(locations: locations)
    }
    #expect(throws: ConfigurationError.self) {
      try MovieFolderEnvironment.makeProcessingRecoveryService(locations: locations)
    }
    let recorder = MovieFolderEnvironment.makeActivityRecorder(locations: locations)
    #expect(await recorder.hasObservedWriteFailure)
    #expect(!(await recorder.record(MovieFolderActivityLogEvent(action: .posterSelection, status: .succeeded))))
    await #expect(throws: (any Error).self) { try await recorder.entries() }
    await #expect(throws: (any Error).self) { try await recorder.clear() }
  }

  /// Activity history can open in a temporary container without becoming a startup requirement.
  @Test func activityFactoryUsesTemporaryContainer() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = MovieFolderEnvironment.makeActivityRecorder(locations: TestStorageLocations(root: root))
    #expect(try await recorder.entries().isEmpty)
    #expect(!(await recorder.hasObservedWriteFailure))
  }
}

/// Test-owned paths replace entitlement-dependent platform resolution only.
private struct TestStorageLocations: MovieFolderStorageLocations {
  /// The temporary root, or absence to simulate platform resolution failure.
  let root: URL?
  func appGroupContainerURL() throws -> URL {
    guard let root else { throw ConfigurationError.unavailableContainer }

    return root
  }
  func applicationSupportURL() throws -> URL { try appGroupContainerURL() }
}
