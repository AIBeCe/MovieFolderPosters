import AppKit
import FileSystem
import Foundation
import MovieFolderCommon
import Testing

@testable import MovieFolderPosters

/// Exercises Settings controls and collection-window actions with isolated service collaborators.
@Suite(.serialized) @MainActor
struct ConfigurationPresentationCoverageTests {
  /// Verifies that the poster layout tab selects the model's saved finish and saves a new choice.
  @Test func posterLayoutControlsReflectAndSaveTheSelectedFinish() async throws {
    let service = PresentationConfigurationService(
      summary: ConfigurationSummary(directories: [], credentialConfigured: false, posterAppearance: .matteFrame))
    let model = ConfigurationViewModel(service: service, activity: PresentationActivityService())
    await model.load()
    let controller = try makeSettingsController(model: model)
    let pane = try #require(controller.tabViewItems[0].viewController)
    let buttons = descendants(pane.view).compactMap { $0 as? PreviewChoiceButton }
    let raw = try #require(buttons.first { $0.title == "Raw" })
    let matte = try #require(buttons.first { $0.title == "Matte frame" })

    #expect(matte.state == .on)
    #expect(raw.state == .off)
    #expect(raw.isEnabled)
    raw.performClick(.none)
    #expect(await service.waitForPosterAppearance(.raw))
    #expect(model.posterAppearance == .raw)
    await waitForSelection(raw: raw, matte: matte)
    #expect(raw.state == .on)
    #expect(matte.state == .off)
  }

  /// Verifies that appearance previews persist the selected mode without changing poster settings.
  @Test func appAppearanceControlsPersistOnlyTheChosenColorMode() throws {
    let model = ConfigurationViewModel(
      service: PresentationConfigurationService(), activity: PresentationActivityService())
    let preferences = AppAppearanceSettings(defaults: try isolatedDefaults())
    let controller = SettingsViewController(viewModel: model, appearanceSettings: preferences)
    let pane = try #require(controller.tabViewItems[2].viewController)
    let buttons = descendants(pane.view).compactMap { $0 as? PreviewChoiceButton }
    let dark = try #require(buttons.first { $0.title == "Dark" })
    let system = try #require(buttons.first { $0.title == "System" })

    #expect(system.state == .on)
    dark.performClick(.none)

    #expect(preferences.choice == .dark)
    #expect(dark.state == .on)
    #expect(system.state == .off)
    #expect(model.posterAppearance == .softFinish)
  }

  /// Verifies that saving a token clears the secure field and reaches only the injected service.
  @Test func tokenSaveClearsFieldAndCallsInjectedConfigurationService() async throws {
    let service = PresentationConfigurationService()
    let model = ConfigurationViewModel(service: service, activity: PresentationActivityService())
    await model.reloadCredentialState()
    let controller = try makeSettingsController(model: model)
    let pane = try #require(controller.tabViewItems[1].viewController)
    let field = try #require(descendants(pane.view).compactMap { $0 as? NSSecureTextField }.first)
    let save = try #require(
      descendants(pane.view).compactMap { $0 as? NSButton }.first { $0.title == "Test and Save Token" })
    field.stringValue = "isolated-test-token"

    save.performClick(.none)

    #expect(field.stringValue.isEmpty)
    #expect(await service.waitForSavedCredential())
    #expect(await service.savedCredential == "isolated-test-token")
  }

  /// Replacement captures a generation and does not submit the secure entry before confirmation.
  @Test func replacementWaitsForCoordinatorConfirmation() async throws {
    let service = PresentationConfigurationService(summary:
      ConfigurationSummary(directories: [], credentialConfigured: true))
    let model = ConfigurationViewModel(service: service, activity: PresentationActivityService())
    await model.reloadCredentialState()
    let controller = try makeSettingsController(model: model)
    let confirmation = CredentialConfirmationProbe()
    controller.credentialDelegate = confirmation
    let pane = try #require(controller.tabViewItems[1].viewController)
    let field = try #require(descendants(pane.view).compactMap { $0 as? NSSecureTextField }.first)
    let save = try #require(descendants(pane.view).compactMap { $0 as? NSButton }
      .first { $0.title == "Test and Replace Token…" })
    field.stringValue = "replacement-fixture"
    save.performClick(.none)
    #expect(await service.savedCredential == .none)
    #expect(field.stringValue == "replacement-fixture")
    let captured = try #require(confirmation.replacementState)
    confirmation.sender?.saveEnteredCredential(expectedState: captured)
    #expect(field.stringValue.isEmpty)
    #expect(await service.waitForSavedCredential())
    #expect(await service.savedCredential == "replacement-fixture")
  }

  /// Saved-token tests and removals route through explicit controls with the loaded credential generation.
  @Test func savedTestRemovalAndHelpActionsUseCredentialDelegate() async throws {
    let service = PresentationConfigurationService(
      summary: ConfigurationSummary(directories: [], credentialConfigured: true))
    let model = ConfigurationViewModel(service: service, activity: PresentationActivityService())
    await model.reloadCredentialState()
    let controller = try makeSettingsController(model: model)
    let confirmation = CredentialConfirmationProbe()
    controller.credentialDelegate = confirmation
    let pane = try #require(controller.tabViewItems[1].viewController)
    let buttons = descendants(pane.view).compactMap { $0 as? NSButton }
    let test = try #require(buttons.first { $0.title == "Test Saved Token" })
    let remove = try #require(buttons.first { $0.title == "Remove Token…" })
    let help = try #require(buttons.first { $0.title == "Open TMDb API Settings…" })

    test.performClick(.none)
    #expect(await service.waitForCredentialTestCount(1))
    #expect(await service.credentialTestCount == 1)
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while model.isBusy, clock.now < deadline { await Task.yield() }
    #expect(!model.isBusy)

    remove.performClick(.none)
    #expect(confirmation.removalState?.isConfigured == true)
    #expect(confirmation.removalState?.revision == model.credentialState?.revision)
    let confirmedState = try #require(confirmation.removalState)
    confirmation.sender?.removeSavedCredential(expectedState: confirmedState)
    #expect(await service.waitForRemovalCount(1))
    #expect(await service.removalCount == 1)
    help.performClick(.none)
    #expect(confirmation.helpRequestCount == 1)

    pane.viewDidDisappear()
  }

  /// Parsing preview is local and exposes supported fields without submitting credentials.
  @Test func localPreviewUsesParserWithoutSavingOrSearching() async throws {
    let service = PresentationConfigurationService()
    let model = ConfigurationViewModel(service: service, activity: PresentationActivityService())
    await model.reloadCredentialState()
    let pane = TMDbPane(viewModel: model)
    let sample = try #require(descendants(pane.view).compactMap { $0 as? NSTextField }
      .first { $0.placeholderString?.hasPrefix("Example:") == true })
    sample.stringValue = "Alien.1979.1080p.BluRay"
    pane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: sample))
    let labels = descendants(pane.view).compactMap { $0 as? NSTextField }.map(\.stringValue)
    #expect(labels.contains { $0.contains("title ‘Alien’; year: 1979") })
    #expect(await service.savedCredential == .none)
    #expect(!model.isBusy)
    sample.stringValue = "Alien (1979) (1980)"
    pane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: sample))
    #expect(descendants(pane.view).compactMap { $0 as? NSTextField }
      .contains { $0.stringValue.contains("cannot be parsed confidently") })
    sample.stringValue = ""
    pane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: sample))
    #expect(descendants(pane.view).compactMap { $0 as? NSTextField }
      .contains { $0.stringValue.contains("Enter a folder name to preview") })
    let tokenField = try #require(descendants(pane.view).compactMap { $0 as? NSSecureTextField }.first)
    tokenField.stringValue = "temporary-entry"
    sample.stringValue = "temporary-preview"
    pane.viewDidDisappear()
    #expect(tokenField.stringValue.isEmpty)
    #expect(sample.stringValue.isEmpty)
  }

  /// Verifies that collection-window buttons forward their actions without opening system pickers.
  @Test func collectionWindowActionsForwardToItsDelegate() async throws {
    let directory = ConfiguredDirectoryStatus(
      id: UUID(), path: "/tmp/PresentationFixture/Movies", availability: .available)
    let model = ConfigurationViewModel(
      service: PresentationConfigurationService(
        summary: ConfigurationSummary(directories: [directory], credentialConfigured: false)),
      activity: PresentationActivityService())
    await model.load()
    let controller = ConfigurationViewController(viewModel: model)
    let delegate = ConfigurationPresentationRouteProbe()
    controller.delegate = delegate
    let buttons = descendants(controller.view).compactMap { $0 as? NSButton }

    try #require(buttons.first { $0.accessibilityLabel() == "Settings" }).performClick(.none)
    try #require(buttons.first { $0.accessibilityLabel() == "Log" }).performClick(.none)
    try #require(buttons.first { $0.title == "Check Installation…" }).performClick(.none)
    try #require(buttons.first { $0.accessibilityLabel() == "Add collection" }).performClick(.none)

    #expect(delegate.routes == ["settings", "log", "installation", "select"])
    #expect(delegate.selectedDirectory == .none)
  }

  /// Verifies the table distinguishes folder access from persisted processing results.
  @Test func collectionRowsRenderAvailabilityAndCommittedCounts() async throws {
    let availableID = UUID()
    let unavailableID = UUID()
    let directories = [
      ConfiguredDirectoryStatus(
        id: availableID, path: "/tmp/PresentationFixture/Movies/First Movie", availability: .available),
      ConfiguredDirectoryStatus(
        id: unavailableID, path: "/tmp/PresentationFixture/Movies/Second Movie", availability: .missing)
    ]
    let model = ConfigurationViewModel(
      service: PresentationConfigurationService(
        summary: ConfigurationSummary(directories: directories, credentialConfigured: false)),
      activity: PresentationActivityService())
    await model.load()
    let availableSummary = CollectionProcessingSummary(
      processingState: .none,
      presentation: CollectionProcessingPresentation(processingState: .none),
      counts: CollectionProcessingCounts(done: 4, notFound: 1, severalMatches: 2, total: 7),
      displayState: .current)
    let summaries = PresentationSummaryService(values: [availableID: availableSummary])
    let summaryModel = CollectionSummaryViewModel(service: summaries)
    summaryModel.reload()
    try await waitForSummaries(summaryModel)

    let controller = ConfigurationViewController(viewModel: model, summaryViewModel: summaryModel)
    let table = try #require(descendants(controller.view).compactMap { $0 as? NSTableView }.first)
    #expect(controller.numberOfRows(in: table) == 2)

    let collectionColumn = try #require(table.tableColumns.first { $0.identifier.rawValue == "collection" })
    let collectionCell = try #require(
      controller.tableView(table, viewFor: collectionColumn, row: 0))
    let collectionLabels = descendants(collectionCell).compactMap { $0 as? NSTextField }
    #expect(collectionLabels.contains { $0.stringValue == "Movies / First Movie" })
    #expect(collectionLabels.contains { $0.stringValue.contains("Host access preflight passed") })
    #expect(collectionLabels.contains { $0.stringValue.contains("Results: Current") })

    let doneColumn = try #require(table.tableColumns.first { $0.identifier.rawValue == "done" })
    let doneCell = try #require(controller.tableView(table, viewFor: doneColumn, row: 0))
    #expect(descendants(doneCell).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "4" })

    let totalColumn = try #require(table.tableColumns.first { $0.identifier.rawValue == "total" })
    let missingTotalCell = try #require(
      controller.tableView(table, viewFor: totalColumn, row: 1))
    let missingTotal = try #require(
      descendants(missingTotalCell).compactMap { $0 as? NSTextField }.first)
    #expect(missingTotal.stringValue == "—")
    #expect(missingTotal.toolTip == "No processing summary is available.")
  }

  /// Creates a Settings controller backed by the supplied isolated configuration model.
  private func makeSettingsController(model: ConfigurationViewModel) throws -> SettingsViewController {
    SettingsViewController(
      viewModel: model,
      appearanceSettings: AppAppearanceSettings(defaults: try isolatedDefaults()))
  }

  /// Creates a distinct preferences suite and fails if the suite cannot be created.
  private func isolatedDefaults() throws -> UserDefaults {
    let name = "ConfigurationPresentationCoverageTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)

    return defaults
  }

  /// Waits for the Settings pane to reflect the model after its save operation completes.
  private func waitForSelection(raw: PreviewChoiceButton, matte: PreviewChoiceButton) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while raw.state != .on || matte.state != .off, clock.now < deadline { await Task.yield() }
  }

  /// Waits for the summary reader to publish the fixture used by row rendering.
  private func waitForSummaries(_ model: CollectionSummaryViewModel) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while model.summaries.isEmpty, clock.now < deadline { await Task.yield() }
    try #require(!model.summaries.isEmpty)
  }

  /// Returns a view and all descendants for focused assertions against actual AppKit controls.
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

/// Captures confirmation requests without opening a native alert or receiving a token.
@MainActor
private final class CredentialConfirmationProbe: CredentialSettingsDelegate {
  /// Submission target retained by the Settings controller, not by this observer.
  weak var sender: (any CredentialSettingsSubmitting)?
  /// Non-secret state frozen before the replacement alert.
  private(set) var replacementState: CredentialState?
  /// Non-secret state frozen before a removal alert.
  private(set) var removalState: CredentialState?
  /// Number of explicit token-help navigation requests.
  private(set) var helpRequestCount = 0
  func credentialSettings(_ sender: any CredentialSettingsSubmitting, requestReplacement state: CredentialState) {
    self.sender = sender
    replacementState = state
  }
  func credentialSettings(_ sender: any CredentialSettingsSubmitting, requestRemoval state: CredentialState) {
    self.sender = sender
    removalState = state
  }
  func credentialSettingsDidRequestTokenHelp(_ sender: NSViewController) { helpRequestCount += 1 }
}

/// Implements the local configuration service with in-memory state for Settings interactions.
private actor PresentationConfigurationService: ConfigurationServicing {
  /// Saved state returned to the view model.
  private var summary: ConfigurationSummary
  /// Most recent token supplied by the Settings pane.
  private(set) var savedCredential: String?
  /// Number of explicit saved-token provider checks.
  private(set) var credentialTestCount = 0
  /// Number of removals explicitly submitted after confirmation.
  private(set) var removalCount = 0
  /// Poster appearance values explicitly saved through the Settings pane.
  private var savedAppearances: [PosterAppearance] = []

  /// Creates a service with a fixed initial Settings state.
  init(summary: ConfigurationSummary = ConfigurationSummary(directories: [], credentialConfigured: false)) {
    self.summary = summary
  }

  /// Returns the current in-memory state without opening persistent storage.
  func configurationSummary() throws -> ConfigurationSummary { summary }

  func addDirectory(_ directory: URL) throws {}
  func removeDirectory(_ identifier: UUID) throws {}
  func reauthorizeDirectory(_ identifier: UUID, _ directory: URL) throws {}

  /// Captures a token in the test service and marks credential presence in its summary.
  /// Returns the isolated fixture's non-secret credential state.
  func credentialState() -> CredentialState {
    CredentialState(isConfigured: summary.credentialConfigured, revision: .none)
  }
  /// Accepts explicit tests without contacting the provider.
  func testCredential(expectedRevision: UUID?) throws { credentialTestCount += 1 }
  func saveCredential(_ value: String, expectedRevision: UUID?) throws {
    savedCredential = value
    summary = ConfigurationSummary(
      directories: summary.directories, credentialConfigured: true,
      posterAppearance: summary.posterAppearance)
  }

  /// Clears credential presence in the isolated summary.
  func removeCredential(expectedRevision: UUID?) throws {
    removalCount += 1
    savedCredential = .none
    summary = ConfigurationSummary(
      directories: summary.directories, credentialConfigured: false,
      posterAppearance: summary.posterAppearance)
  }

  /// Persists the selected poster appearance only in actor memory.
  func setPosterAppearance(_ appearance: PosterAppearance) throws {
    savedAppearances.append(appearance)
    summary = ConfigurationSummary(
      directories: summary.directories, credentialConfigured: summary.credentialConfigured,
      posterAppearance: appearance)
  }

  /// Yields until the Save Token action reaches the isolated service.
  func waitForSavedCredential() async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while savedCredential == .none, clock.now < deadline { await Task.yield() }

    return savedCredential != .none
  }

  /// Yields until the requested number of saved-token tests reaches the service.
  func waitForCredentialTestCount(_ count: Int) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while credentialTestCount < count, clock.now < deadline { await Task.yield() }

    return credentialTestCount >= count
  }

  /// Yields until the requested number of confirmed removals reaches the service.
  func waitForRemovalCount(_ count: Int) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while removalCount < count, clock.now < deadline { await Task.yield() }

    return removalCount >= count
  }

  /// Yields until the selected poster finish reaches the isolated service.
  func waitForPosterAppearance(_ appearance: PosterAppearance) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while !savedAppearances.contains(appearance), clock.now < deadline { await Task.yield() }

    return savedAppearances.contains(appearance)
  }
}

/// Accepts activity events without using shared storage.
private actor PresentationActivityService: MovieFolderActivityServicing {
  func record(_ event: MovieFolderActivityEvent) -> Bool { true }
  func entries() throws -> [MovieFolderActivityEntry] { [] }
  func clear() throws {}
}

/// Returns deterministic processing projections without opening persistence stores.
private struct PresentationSummaryService: CollectionSummaryServicing {
  /// Projections keyed by configured collection identifier.
  let values: [UUID: CollectionProcessingSummary]

  func summaries() -> [UUID: CollectionProcessingSummary] { values }
}

/// Captures the collection view's navigation and directory-selection actions.
@MainActor
private final class ConfigurationPresentationRouteProbe: ConfigurationViewControllerDelegate {
  /// Actions received in order from the actual AppKit controls.
  private(set) var routes: [String] = []
  /// Identifier requested by folder selection, or `nil` for a new collection.
  private(set) var selectedDirectory: UUID?

  func configurationViewControllerDidRequestSettings(_ controller: ConfigurationViewController) {
    routes.append("settings")
  }

  func configurationViewControllerDidRequestLog(_ controller: ConfigurationViewController) { routes.append("log") }

  func configurationViewControllerDidRequestInstallationReadiness(_ controller: ConfigurationViewController) {
    routes.append("installation")
  }

  func configurationViewController(
    _ controller: ConfigurationViewController, didRequestDirectorySelection identifier: UUID?
  ) {
    routes.append("select")
    selectedDirectory = identifier
  }
}
