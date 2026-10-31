import AppKit
import FileSystem
import Foundation
import MovieFolderCommon
import Persistence
import Testing

@testable import MovieFolderPosters

/// Covers configuration state updates, error handling, and AppKit presentation behavior.
struct ConfigurationViewModelTests {
  /// Keeps installation diagnostics independent of collection refresh and change.
  @Test @MainActor
  func installationDiagnosticDoesNotRefreshOrMutateCollectionConfiguration() async {
    let service = ConfigurationServiceFake()
    let coordinator = ConfigurationCoordinator(
      service: service, installationService: InstallationServiceFake())
    let report = await coordinator.installationReport()
    #expect(service.calls.isEmpty)
    #expect(report.text.contains("Controlled installation evidence"))
    #expect(report.text.contains("Setup has not been loaded"))
  }

  /// Verifies unavailable authorization evidence has both visible and accessible explanations.
  @Test @MainActor
  func readinessHasVisibleTextAndAccessibleExplanation() async throws {
    let model = ConfigurationViewModel(
      service: ConfigurationServiceFake(
        summary: ConfigurationSummary(
          directories: [.init(id: UUID(), path: "/Movies", availability: .checkUnavailable)],
          credentialConfigured: false
        )))
    await model.load()
    let controller = ConfigurationViewController(viewModel: model)
    /// Collects the view and all descendants for native control assertions.
    /// - Parameter view: Root of the view hierarchy to inspect.
    /// - Returns: The root followed by its descendants in traversal order.
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let table = try #require(descendants(controller.view).compactMap { $0 as? NSTableView }.first)
    table.reloadData()
    let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
    #expect(
      descendants(cell).compactMap { $0 as? NSTextField }.contains {
        $0.stringValue.contains("Authorization records are busy")
      })
    #expect(
      descendants(cell).compactMap { $0 as? NSImageView }.contains {
        $0.accessibilityLabel()?.contains("Authorization records are busy") == true
      })
  }

  /// Verifies the configuration view constructs its native layout.
  @Test @MainActor
  func configurationViewLoadsWithoutLayoutExceptions() {
    let viewModel = ConfigurationViewModel(service: ConfigurationServiceFake())
    let controller = ConfigurationViewController(viewModel: viewModel)

    #expect(!controller.view.subviews.isEmpty)
  }

  /// Verifies loading publishes configured roots, credential status, and poster appearance.
  @Test @MainActor
  func loadPublishesConfiguredDirectoriesAndCredentialState() async {
    let directory = ConfiguredDirectoryStatus(id: UUID(), path: "/Movies", availability: .available)
    let service = ConfigurationServiceFake(
      summary: ConfigurationSummary(
        directories: [directory], credentialConfigured: true, posterAppearance: .matteFrame
      ))
    let viewModel = ConfigurationViewModel(service: service)

    await viewModel.load()

    #expect(viewModel.directories == [directory])
    #expect(viewModel.credentialConfigured)
    #expect(viewModel.posterAppearance == .matteFrame)
    #expect(!viewModel.isBusy)
    #expect(viewModel.errorMessage == .none)
  }

  /// Verifies an appearance change saves its selection and reloads presentation state.
  @Test @MainActor
  func changingAppearancePersistsAndRefreshesTheVisibleSummary() async {
    let service = ConfigurationServiceFake()
    let viewModel = ConfigurationViewModel(service: service)

    await viewModel.load()
    #expect(viewModel.posterAppearance == .softFinish)
    await viewModel.setPosterAppearance(.matteFrame)

    #expect(viewModel.posterAppearance == .matteFrame)
    #expect(service.calls.contains(.setPosterAppearance(.matteFrame)))
    #expect(!viewModel.isBusy)
    #expect(viewModel.errorMessage == .none)
  }

  /// Restores the persisted appearance when saving the requested choice fails.
  @Test @MainActor
  func failedAppearanceChangeRevertsToLastSavedChoice() async {
    let service = ConfigurationServiceFake(
      summary: ConfigurationSummary(
        directories: [], credentialConfigured: false, posterAppearance: .raw
      ))
    let viewModel = ConfigurationViewModel(service: service)
    await viewModel.load()
    service.failNextAction(with: TestServiceError(message: "write failed"))

    await viewModel.setPosterAppearance(.matteFrame)

    #expect(viewModel.posterAppearance == .raw)
    #expect(viewModel.errorMessage == "Could not save the poster appearance.")
    #expect(!viewModel.isBusy)
  }

  /// Rejects overlapping appearance mutations while the first change is pending.
  @Test @MainActor
  func appearanceChangeIsSerializedWithOtherConfigurationChanges() async {
    let gate = AsyncTaskGate()
    let service = ConfigurationServiceFake(gate: gate)
    let viewModel = ConfigurationViewModel(service: service)
    let change = Task { await viewModel.setPosterAppearance(.raw) }
    await gate.waitUntilEntered()
    #expect(viewModel.isBusy)

    await viewModel.setPosterAppearance(.matteFrame)
    #expect(service.calls == [.setPosterAppearance(.raw)])

    await gate.open()
    await change.value
    #expect(service.calls == [.setPosterAppearance(.raw), .configurationSummary])
    #expect(viewModel.posterAppearance == .raw)
    #expect(!viewModel.isBusy)
  }

  /// Verifies successful root and credential changes refresh the displayed configuration.
  @Test @MainActor
  func successfulDirectoryAndCredentialActionsRefreshTheVisibleSummary() async {
    let service = ConfigurationServiceFake()
    let viewModel = ConfigurationViewModel(service: service)
    let directory = URL(fileURLWithPath: "/Movies/Drama", isDirectory: true)

    await viewModel.addDirectory(directory)
    await viewModel.saveCredential("private-token")
    await viewModel.removeCredential()

    #expect(viewModel.directories.map(\.path) == ["/Movies/Drama"])
    #expect(!viewModel.credentialConfigured)
    #expect(service.calls.contains(.add(directory)))
    #expect(service.calls.contains(.saveCredential("private-token")))
    #expect(service.calls.contains(.removeCredential))
  }

  /// Verifies reauthorization restores access and removal clears the configured row.
  @Test @MainActor
  func reauthorizationRestoresStatusAndRemovalDropsTheDirectory() async {
    let directoryID = UUID()
    let directory = ConfiguredDirectoryStatus(
      id: directoryID, path: "/Volumes/Movies", availability: .reauthorizationRequired
    )
    let service = ConfigurationServiceFake(
      summary: ConfigurationSummary(
        directories: [directory], credentialConfigured: false, posterAppearance: .softFinish
      ))
    let viewModel = ConfigurationViewModel(service: service)
    let replacementURL = URL(fileURLWithPath: "/Volumes/Movies", isDirectory: true)

    await viewModel.load()
    await viewModel.reauthorizeDirectory(directoryID, with: replacementURL)

    #expect(viewModel.directories.count == 1)
    #expect(viewModel.directories.first?.id == directoryID)
    #expect(viewModel.directories.first?.path == "/Volumes/Movies")
    #expect(viewModel.directories.first?.availability == .available)

    await viewModel.removeDirectory(directoryID)

    #expect(viewModel.directories.isEmpty)
    #expect(
      service.calls == [
        .configurationSummary,
        .reauthorize(directoryID, replacementURL),
        .configurationSummary,
        .remove(directoryID),
        .configurationSummary
      ])
  }

  /// A failed presentation read must not report an already committed removal as a failed removal.
  @Test @MainActor
  func removalRefreshFailureDoesNotRecordFalseFailureOrDuplicateSuccess() async throws {
    let directory = ConfiguredDirectoryStatus(id: UUID(), path: "/Movies", availability: .available)
    let service = ConfigurationServiceFake(
      summary: ConfigurationSummary(directories: [directory], credentialConfigured: false),
      failsSummaryAfterRemoval: true)
    let activityHistoryService = MovieFolderActivityServiceFake()
    let viewModel = ConfigurationViewModel(service: service, activity: activityHistoryService)
    await viewModel.load()
    await viewModel.removeDirectory(directory.id)

    #expect(service.calls.contains(.remove(directory.id)))
    #expect(viewModel.errorMessage?.contains("was removed") == true)
    #expect(try await activityHistoryService.entries().allSatisfy { $0.event.action != .collectionRemoved })
    #expect(!viewModel.isBusy)
  }

  /// Verifies operation failures expose a safe message without repeating credential text.
  @Test @MainActor
  func failedCredentialActionShowsSafeMessageWithoutEchoingCredential() async {
    let service = ConfigurationServiceFake()
    let viewModel = ConfigurationViewModel(service: service)
    let secret = "private-token"
    service.failNextAction(with: TestServiceError(message: "Rejected \(secret)"))

    await viewModel.saveCredential(secret)

    #expect(viewModel.errorMessage == "Could not save the API credential.")
    #expect(!(viewModel.errorMessage?.contains(secret) ?? false))
    #expect(!viewModel.isBusy)
  }

  /// Prevents a second change while the current configuration operation is suspended.
  @Test @MainActor
  func busyActionRejectsAnotherChangeUntilTheFirstCompletes() async {
    let gate = AsyncTaskGate()
    let service = ConfigurationServiceFake(gate: gate)
    let viewModel = ConfigurationViewModel(service: service)
    let first = URL(fileURLWithPath: "/Movies/First", isDirectory: true)
    let second = URL(fileURLWithPath: "/Movies/Second", isDirectory: true)

    let firstOperation = Task { await viewModel.addDirectory(first) }
    await gate.waitUntilEntered()
    #expect(viewModel.isBusy)

    await viewModel.addDirectory(second)
    #expect(service.calls == [.add(first)])

    await gate.open()
    await firstOperation.value

    #expect(!viewModel.isBusy)
    #expect(service.calls == [.add(first), .configurationSummary])
  }
}
