import Foundation
import Testing

@testable import Common

/// Factories must use the injected locations without opening the real signed App Group.
struct MovieFolderEnvironmentTests {
  /// Settings, collection outcomes, and authorization remain in distinct persistence namespaces.
  @Test func factoriesReopenOnlyTheSuppliedDirectories() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let locations = TestStorageLocations(root: root)
    let repository = try MovieFolderServiceFactory(locations: locations).makeConfigurationRepository()
    try repository.update { $0.usesStubTMDbResponses = true }
    let reopened = try MovieFolderServiceFactory(locations: locations).makeConfigurationRepository()
    #expect(try reopened.read().usesStubTMDbResponses)
    _ = try MovieFolderServiceFactory(locations: locations).makeCollectionProcessingStore()
    _ = try MovieFolderServiceFactory(locations: locations).makePrivateAuthorizationStore()
    let recovery = try MovieFolderServiceFactory(locations: locations).makeProcessingRecoveryService()
    try recovery.setRecoveryModeEnabled(true)
    let reopenedRecovery = try MovieFolderServiceFactory(locations: locations).makeProcessingRecoveryService()
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
    let factory = MovieFolderServiceFactory(locations: locations)
    #expect(throws: ConfigurationError.self) {
      try MovieFolderServiceFactory(locations: locations).makeConfigurationRepository()
    }
    #expect(throws: ConfigurationError.self) {
      try MovieFolderServiceFactory(locations: locations).makeCollectionProcessingStore()
    }
    #expect(throws: ConfigurationError.self) {
      try MovieFolderServiceFactory(locations: locations).makePrivateAuthorizationStore()
    }
    #expect(throws: ConfigurationError.self) {
      try MovieFolderServiceFactory(locations: locations).makeProcessingRecoveryService()
    }
    let recorder = factory.makeActivityRecorder()
    #expect(await recorder.hasObservedWriteFailure)
    #expect(!(await recorder.record(MovieFolderActivityLogEvent(action: .posterSelection, status: .succeeded))))
    await #expect(throws: (any Error).self) { try await recorder.entries() }
    await #expect(throws: (any Error).self) { try await recorder.clear() }
    let networkHistory = factory.makeNetworkHistoryService()
    #expect(await networkHistory.prepareNetworkHistoryRecording(collectionID: .none) == .none)
    await #expect(throws: (any Error).self) { try await networkHistory.entries() }
  }

  /// Activity history can open in a temporary container without becoming a startup requirement.
  @Test func activityFactoryUsesTemporaryContainer() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = MovieFolderServiceFactory(locations: TestStorageLocations(root: root)).makeActivityRecorder()
    #expect(try await recorder.entries().isEmpty)
    #expect(!(await recorder.hasObservedWriteFailure))
  }
}

/// Test-owned paths replace entitlement-dependent platform resolution only.
private struct TestStorageLocations: MovieFolderApplicationStorageLocations {
  /// The temporary root, or absence to simulate platform resolution failure.
  let root: URL?
  func appGroupContainerURL() throws -> URL {
    guard let root else { throw ConfigurationError.unavailableContainer }

    return root
  }
  func applicationSupportURL() throws -> URL { try appGroupContainerURL() }
}
