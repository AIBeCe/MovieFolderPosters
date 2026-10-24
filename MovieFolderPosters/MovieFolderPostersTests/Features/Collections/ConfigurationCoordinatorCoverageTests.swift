import AppKit
import FileSystem
import Foundation
import MovieFolderCommon
import Testing

@testable import MovieFolderPosters

/// Covers coordinator routes that combine injected services with real AppKit windows and sheets.
@Suite(.serialized) @MainActor
struct ConfigurationCoordinatorCoverageTests {
  /// Main opens the focused results sheet without changing configuration or starting provider work.
  @Test func unresolvedResultsOpenAndCloseWithoutConfigurationChange() async throws {
    let rootID = UUID()
    let directory = ConfiguredDirectoryStatus(
      id: rootID, path: "/tmp/CoordinatorFixture/Movies", availability: .available)
    let service = ConfigurationCoverageService(
      summary: ConfigurationSummary(directories: [directory], credentialConfigured: false))
    let activity = ConfigurationCoverageActivity()
    let coordinator = try makeCoordinator(service: service, activity: activity)
    coordinator.start()
    let window = try #require(coordinator.mainWindow?.window)
    defer { closeSheetsAndWindow(window) }
    let main = try #require(window.contentViewController as? ConfigurationViewController)
    try await waitForConfigurationLoad(service: service, activity: activity, controller: main)
    coordinator.configurationViewControllerDidRequestUnresolvedResults(main, rootID: rootID)
    let sheet = try #require(coordinator.resultsWindow)
    #expect(sheet.sheetParent === window)
    #expect(sheet.title == "Unresolved Results — Movies")
    let results = try #require(sheet.contentViewController as? CollectionResultsViewController)
    let closeButton = try #require(descendants(results.view).compactMap { $0 as? NSButton }
      .first { $0.title == "Close" })
    #expect(closeButton.isEnabled && !closeButton.isHidden)
    closeButton.performClick(.none)
    #expect(coordinator.resultsWindow == .none)
    #expect(window.attachedSheet == .none)
    #expect(await service.configurationChangeCount == .zero)
  }

  /// Verifies that overlapping readiness requests share one in-flight evidence check.
  @Test func installationRequestCoalescesOverlappingChecks() async throws {
    let service = ConfigurationCoverageService()
    let activity = ConfigurationCoverageActivity()
    let installation = ConfigurationCoverageInstallation()
    let coordinator = try makeCoordinator(
      service: service, activity: activity, installation: installation)
    coordinator.start()
    let window = try #require(coordinator.mainWindow?.window)
    defer { closeSheetsAndWindow(window) }
    let controller = try #require(coordinator.mainWindow?.contentViewController as? ConfigurationViewController)
    try await waitForConfigurationLoad(service: service, activity: activity, controller: controller)
    #expect(window.isVisible)

    coordinator.configurationViewControllerDidRequestInstallationReadiness(controller)
    await installation.waitForChecks(1)
    coordinator.configurationViewControllerDidRequestInstallationReadiness(controller)
    #expect(await installation.checkCount == 1)
    await installation.completeCheck()
    await installation.waitForCompletions(1)
    #expect(window.isVisible)
  }

  /// Verifies that collection details use the committed summary without configuration writes.
  @Test func processingDetailsRequestDoesNotMutateConfiguration() async throws {
    let rootID = UUID()
    let directory = ConfiguredDirectoryStatus(
      id: rootID, path: "/tmp/CoordinatorFixture/Movies", availability: .available)
    let summary = CollectionProcessingSummary(
      processingState: .none,
      presentation: CollectionProcessingPresentation(processingState: .none),
      counts: CollectionProcessingCounts(done: .none, notFound: .none, severalMatches: .none, total: .none),
      displayState: .unavailable)
    let summaryService = ConfigurationCoverageSummary(summaries: [rootID: summary])
    let service = ConfigurationCoverageService(
      summary: ConfigurationSummary(directories: [directory], credentialConfigured: false))
    let activity = ConfigurationCoverageActivity()
    let coordinator = try makeCoordinator(service: service, activity: activity, summary: summaryService)
    coordinator.start()
    let window = try #require(coordinator.mainWindow?.window)
    defer { closeSheetsAndWindow(window) }
    let controller = try #require(coordinator.mainWindow?.contentViewController as? ConfigurationViewController)
    try await waitForConfigurationLoad(service: service, activity: activity, controller: controller)
    await summaryService.waitForCalls(1)
    #expect(window.isVisible)
    let existingWindows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))

    coordinator.configurationViewControllerDidRequestProcessingDetails(controller, rootID: rootID)

    let detailsWindow = try #require(
      NSApplication.shared.windows.first { !existingWindows.contains(ObjectIdentifier($0)) })
    #expect(detailsWindow.title == "Processing Details — Movies")
    let details = try #require(detailsWindow.contentViewController as? CollectionProcessingDetailsViewController)
    let textView = try #require(descendants(details.view).compactMap { $0 as? NSTextView }.first)
    #expect(textView.isSelectable)
    #expect(!textView.isEditable)
    #expect(textView.string.contains("No committed processing outcome is available"))
    #expect(await summaryService.callCount == 1)
    #expect(await service.configurationChangeCount == 0)
    let closeButton = try #require(descendants(details.view).compactMap { $0 as? NSButton }
      .first { $0.title == "Close" })
    #expect(closeButton.isEnabled && !closeButton.isHidden)
    closeButton.performClick(.none)
    #expect(window.attachedSheet == .none)
  }

  /// Verifies that activation and explicit refresh each request a fresh committed summary.
  @Test func activationAndExplicitRefreshReloadProcessingSummary() async throws {
    let summaryService = ConfigurationCoverageSummary()
    let coordinator = try makeCoordinator(summary: summaryService)

    coordinator.applicationDidBecomeActive()
    await summaryService.waitForCalls(1)
    coordinator.refreshCollectionProcessingState()
    await summaryService.waitForCalls(2)

    #expect(await summaryService.callCount == 2)
  }

  /// Verifies that sibling log requests and activity outcomes reach the root delegate.
  @Test func logAndActivityCallbacksAreForwardedToRootDelegate() throws {
    let coordinator = try makeCoordinator()
    let delegate = CoordinatorRouteProbe()
    coordinator.delegate = delegate
    let model = ConfigurationViewModel(
      service: ConfigurationCoverageService(), activity: ConfigurationCoverageActivity())
    let controller = ConfigurationViewController(viewModel: model)
    let event = MovieFolderActivityEvent(action: .collectionAdded, status: .failed)

    coordinator.configurationViewControllerDidRequestLog(controller)
    coordinator.configurationViewModel(model, didRecordActivity: event, saved: false)
    coordinator.configurationViewModel(model, didRecordActivity: event, saved: true)

    #expect(delegate.logRequestCount == 1)
    #expect(delegate.lastLogCoordinator === coordinator)
    #expect(delegate.activityOutcomes == [false, true])
    #expect(delegate.lastActivityCoordinator === coordinator)
  }

  /// Creates the coordinator with collaborators that cannot reach user stores or credentials.
  private func makeCoordinator(
    service: ConfigurationCoverageService? = .none,
    activity: ConfigurationCoverageActivity? = .none,
    installation: ConfigurationCoverageInstallation? = .none,
    summary: ConfigurationCoverageSummary? = .none
  ) throws -> ConfigurationCoordinator {
    _ = NSApplication.shared

    return ConfigurationCoordinator(
      service: service ?? ConfigurationCoverageService(),
      activity: activity ?? ConfigurationCoverageActivity(),
      summaryService: summary ?? ConfigurationCoverageSummary(),
      appearance: AppAppearanceSettings(defaults: try isolatedDefaults()),
      installationService: installation ?? ConfigurationCoverageInstallation())
  }

  /// Creates a private preference domain for the coordinator's appearance setting.
  private func isolatedDefaults() throws -> UserDefaults {
    let name = "ConfigurationCoordinatorCoverageTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)

    return defaults
  }

  /// Waits for the real view model's initial load and its best-effort activity record.
  private func waitForConfigurationLoad(
    service: ConfigurationCoverageService, activity: ConfigurationCoverageActivity,
    controller: ConfigurationViewController
  ) async throws {
    await service.waitForSummaryReads(1)
    await activity.waitForRecords(1)
    let addButton = try #require(
      descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Add collection" })
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while !addButton.isEnabled, clock.now < deadline { await Task.yield() }
    try #require(addButton.isEnabled)
  }

  /// Closes an attached sheet and its owner window at test teardown.
  private func closeSheetsAndWindow(_ window: NSWindow) {
    if let sheet = window.attachedSheet { window.endSheet(sheet) }
    window.close()
  }

  /// Returns a view and all descendants for assertions against actual AppKit presentation.
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

}

/// Provides a deterministic configuration summary and counts initial reads.
private actor ConfigurationCoverageService: ConfigurationServicing {
  /// Summary returned to the configuration view model.
  private let summary: ConfigurationSummary
  /// Number of summary reads completed by this service.
  private(set) var summaryReadCount = Int.zero
  /// Number of configuration mutations requested through this service.
  private(set) var configurationChangeCount = Int.zero

  /// Creates a service with the fixed state shown by the coordinator.
  init(summary: ConfigurationSummary = ConfigurationSummary(directories: [], credentialConfigured: false)) {
    self.summary = summary
  }

  /// Returns the configured fixture and records completion of the read.
  func configurationSummary() throws -> ConfigurationSummary {
    summaryReadCount += 1

    return summary
  }

  func addDirectory(_ directory: URL) throws { configurationChangeCount += 1 }
  func removeDirectory(_ identifier: UUID) throws { configurationChangeCount += 1 }
  func reauthorizeDirectory(_ identifier: UUID, _ directory: URL) throws { configurationChangeCount += 1 }
  /// Returns the isolated fixture's non-secret credential state.
  func credentialState() -> CredentialState {
    CredentialState(isConfigured: summary.credentialConfigured, revision: .none)
  }
  /// Accepts explicit tests without contacting the provider.
  func testCredential(expectedRevision: UUID?) throws {}
  func saveCredential(_ value: String, expectedRevision: UUID?) throws { configurationChangeCount += 1 }
  func removeCredential(expectedRevision: UUID?) throws { configurationChangeCount += 1 }
  func setPosterAppearance(_ appearance: PosterAppearance) throws { configurationChangeCount += 1 }

  /// Yields until the requested number of configuration reads has completed.
  func waitForSummaryReads(_ count: Int) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while summaryReadCount < count, clock.now < deadline { await Task.yield() }
  }
}

/// Records activity locally without opening shared persistence.
private actor ConfigurationCoverageActivity: MovieFolderActivityServicing {
  /// Number of best-effort writes requested by the view model.
  private(set) var recordCount = Int.zero

  /// Counts the event and reports successful local recording.
  func record(_ event: MovieFolderActivityEvent) -> Bool {
    recordCount += 1

    return true
  }

  func entries() throws -> [MovieFolderActivityEntry] { [] }
  func clear() throws {}

  /// Yields until the requested number of activity writes has been attempted.
  func waitForRecords(_ count: Int) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while recordCount < count, clock.now < deadline { await Task.yield() }
  }
}

/// Supplies controlled installation evidence and exposes read completion to the test.
private actor ConfigurationCoverageInstallation: InstallationReadinessServicing {
  /// Number of readiness reports requested by the coordinator.
  private(set) var checkCount = Int.zero
  /// Number of held report calls that returned to the coordinator.
  private(set) var completedCheckCount = Int.zero
  /// Holds the active report until the test exercises the coordinator's overlap guard.
  private var checkContinuation: CheckedContinuation<Void, Never>?

  /// Returns safe fixed evidence after recording the explicit check.
  func check() async -> InstallationReadinessReport {
    checkCount += 1
    await withCheckedContinuation { checkContinuation = $0 }
    completedCheckCount += 1

    return InstallationReadinessReport(text: "Isolated installation fixture")
  }

  /// Completes the report currently held by the deterministic test gate.
  func completeCheck() {
    checkContinuation?.resume()
    checkContinuation = .none
  }

  /// Yields until the requested number of held reports has returned.
  func waitForCompletions(_ count: Int) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while completedCheckCount < count, clock.now < deadline { await Task.yield() }
  }

  /// Yields until the requested number of report checks has completed.
  func waitForChecks(_ count: Int) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while checkCount < count, clock.now < deadline { await Task.yield() }
  }
}
/// Returns controlled processing projections and counts reload requests.
private actor ConfigurationCoverageSummary: CollectionSummaryServicing {
  /// Projections returned for configured roots.
  private let result: [UUID: CollectionProcessingSummary]
  /// Number of read-only summary requests received.
  private(set) var callCount = Int.zero

  /// Creates a summary service with the fixture result.
  init(summaries: [UUID: CollectionProcessingSummary] = [:]) { result = summaries }

  /// Records the read and returns the fixed result without accessing shared storage.
  func summaries() -> [UUID: CollectionProcessingSummary] {
    callCount += 1

    return result
  }

  /// Yields until the requested number of summary requests has started.
  func waitForCalls(_ count: Int) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while callCount < count, clock.now < deadline { await Task.yield() }
  }
}

/// Captures sibling-flow routing and activity-save outcomes from the coordinator.
@MainActor
private final class CoordinatorRouteProbe: ConfigurationCoordinatorDelegate {
  /// Number of log presentations requested by configuration.
  private(set) var logRequestCount = Int.zero
  /// Most recent configuration flow requesting the log.
  private(set) weak var lastLogCoordinator: ConfigurationCoordinator?
  /// Activity write results forwarded in call order.
  private(set) var activityOutcomes: [Bool] = []
  /// Most recent configuration flow reporting an activity result.
  private(set) weak var lastActivityCoordinator: ConfigurationCoordinator?

  /// Records the originating coordinator's request for the sibling log flow.
  func configurationCoordinatorDidRequestLog(_ coordinator: ConfigurationCoordinator) {
    logRequestCount += 1
    lastLogCoordinator = coordinator
  }

  /// Records the activity result independently of whether it was saved.
  func configurationCoordinator(_ coordinator: ConfigurationCoordinator, didRecordActivitySaved saved: Bool) {
    activityOutcomes.append(saved)
    lastActivityCoordinator = coordinator
  }
}
