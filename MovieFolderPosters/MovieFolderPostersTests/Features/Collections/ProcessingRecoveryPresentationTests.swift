import AppKit
import Foundation
import MovieFolderCommon
import Persistence
import Testing

@testable import MovieFolderPosters

/// Verifies durable recovery controls without changing configuration generations or starting processing.
@MainActor struct ProcessingRecoveryPresentationTests {
  /// Launch entry persists before a caller can proceed and never reenables after an explicit resume.
  @Test func launchRecoveryIsDurableAndPreparedOnlyOnce() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recovery = ProcessingRecoveryService(store: try PersistenceStore(directory: directory))
    let launch = ProcessingRecoveryLaunchController(arguments: ["app", "--recovery-mode"], recovery: recovery)

    try launch.prepare()
    #expect(try recovery.read().isRecoveryModeEnabled)
    try recovery.setRecoveryModeEnabled(false)
    try launch.prepare()
    #expect(try !recovery.read().isRecoveryModeEnabled)
  }

  /// Enter and resume alter only durable admission, preserving configuration and avoiding automatic replay.
  @Test func controlsPublishDurableModeWithoutReloadingConfiguration() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recovery = ProcessingRecoveryService(store: try PersistenceStore(directory: directory))
    let service = ConfigurationServiceFake()
    let model = ConfigurationViewModel(service: service, activity: ActivityServiceFake(), recovery: recovery)
    await model.reloadRecoveryMode()
    #expect(model.isRecoveryModeAvailable)
    #expect(!model.isRecoveryModeEnabled)
    await model.setRecoveryModeEnabled(true)
    #expect(try recovery.read().isRecoveryModeEnabled)
    #expect(model.recoveryModeDescription.contains("Recovery mode enabled"))
    #expect(!model.hasLoadedSummary)
    let controller = ConfigurationViewController(viewModel: model)
    let button = try #require(nativeViews(in: controller.view).compactMap { $0 as? NSButton }
      .first { $0.accessibilityIdentifier() == "processingRecoveryMode" })
    #expect(button.title == "Resume Processing")
    await model.setRecoveryModeEnabled(false)
    #expect(try !recovery.read().isRecoveryModeEnabled)
    #expect(button.title == "Enable Recovery Mode")
    #expect(!model.hasLoadedSummary)
  }

  /// Lock contention leaves mode unchanged and supplies a safe actionable error.
  @Test func failedModeChangeKeepsLastObservedState() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recovery = ProcessingRecoveryService(store: try PersistenceStore(directory: directory))
    let model = ConfigurationViewModel(
      service: ConfigurationServiceFake(), activity: ActivityServiceFake(), recovery: recovery)
    await model.reloadRecoveryMode()
    let mutation = try recovery.acquireMutationLease()
    await model.setRecoveryModeEnabled(true)
    #expect(!model.isRecoveryModeEnabled)
    #expect(!model.isRecoveryModeAvailable)
    #expect(model.errorMessage == ProcessingRecoveryError.busy.localizedDescription)
    withExtendedLifetime(mutation) {}
  }
}
