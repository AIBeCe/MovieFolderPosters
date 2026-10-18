import MovieFolderCommon
import AppKit
import FileSystem
import Foundation
import Persistence
import Testing

@testable import MovieFolderPosters

/// Covers configuration state updates, error handling, and AppKit presentation behavior.
struct ConfigurationViewModelTests {
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

  @Test @MainActor
  func configurationViewLoadsWithoutLayoutExceptions() {
    let viewModel = ConfigurationViewModel(service: ConfigurationServiceFake())
    let controller = ConfigurationViewController(viewModel: viewModel)

    #expect(!controller.view.subviews.isEmpty)
  }

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
    #expect(viewModel.errorMessage == nil)
  }

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
    #expect(viewModel.errorMessage == nil)
  }

  @Test @MainActor
  func failedAppearanceChangeRevertsToLastSavedChoice() async {
    let service = ConfigurationServiceFake(
      summary: ConfigurationSummary(
        directories: [], credentialConfigured: false, posterAppearance: .raw
      ))
    let viewModel = ConfigurationViewModel(service: service)
    await viewModel.load()
    service.failNextOperation(with: TestServiceError(message: "write failed"))

    await viewModel.setPosterAppearance(.matteFrame)

    #expect(viewModel.posterAppearance == .raw)
    #expect(viewModel.errorMessage == "Could not save the poster appearance.")
    #expect(!viewModel.isBusy)
  }

  @Test @MainActor
  func appearanceChangeIsSerializedWithOtherConfigurationMutations() async {
    let gate = AsyncOperationGate()
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

    #expect(
      viewModel.directories == [
        ConfiguredDirectoryStatus(
          id: directoryID, path: "/Volumes/Movies", availability: .available
        )
      ])

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

  @Test @MainActor
  func failedOperationShowsSafeMessageWithoutEchoingCredential() async {
    let service = ConfigurationServiceFake()
    let viewModel = ConfigurationViewModel(service: service)
    let secret = "private-token"
    service.failNextOperation(with: TestServiceError(message: "Rejected \(secret)"))

    await viewModel.saveCredential(secret)

    #expect(viewModel.errorMessage == "Could not save the API credential.")
    #expect(!(viewModel.errorMessage?.contains(secret) ?? false))
    #expect(!viewModel.isBusy)
  }

  @Test @MainActor
  func busyOperationRejectsAnotherMutationUntilTheFirstCompletes() async {
    let gate = AsyncOperationGate()
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

/// Identifies the operation recorded by the fake configuration service.
private enum ConfigurationServiceCall: Equatable {
  case configurationSummary
  case add(URL)
  case remove(UUID)
  case reauthorize(UUID, URL)
  case saveCredential(String)
  case removeCredential
  case setPosterAppearance(PosterAppearance)
}

/// An error value whose message can be checked for safe presentation.
private struct TestServiceError: Error, Sendable {
  /// The underlying message used by the fake service.
  let message: String
}

/// Thread-safe configuration fake with controllable failures and operation gating.
private final class ConfigurationServiceFake: ConfigurationServicing, @unchecked Sendable {
  /// Protects mutable fake state accessed across service calls.
  private let lock = NSLock()
  /// Summary returned by configuration reads and updated by fake mutations.
  private var currentSummary: ConfigurationSummary
  /// Ordered history of calls made by the view model.
  private var recordedCalls: [ConfigurationServiceCall] = []
  /// Error consumed by the next recorded operation.
  private var nextError: TestServiceError?
  /// Optional gate used to hold one operation in progress for serialization tests.
  private let gate: AsyncOperationGate?

  /// Creates a fake with an initial summary and optional operation gate.
  init(
    summary: ConfigurationSummary = ConfigurationSummary(
      directories: [], credentialConfigured: false, posterAppearance: .softFinish
    ),
    gate: AsyncOperationGate? = nil
  ) {
    currentSummary = summary
    self.gate = gate
  }

  /// Recorded service calls in invocation order.
  var calls: [ConfigurationServiceCall] {
    lock.withLock { recordedCalls }
  }

  /// Configures the next recorded operation to throw the supplied error.
  func failNextOperation(with error: TestServiceError) {
    lock.withLock { nextError = error }
  }

  func configurationSummary() async throws -> ConfigurationSummary {
    try record(.configurationSummary)

    return lock.withLock { currentSummary }
  }

  func addDirectory(_ directory: URL) async throws {
    try await prepare(.add(directory))
    lock.withLock {
      let status = ConfiguredDirectoryStatus(
        id: UUID(), path: directory.path, availability: .available
      )
      currentSummary = ConfigurationSummary(
        directories: currentSummary.directories + [status],
        credentialConfigured: currentSummary.credentialConfigured,
        posterAppearance: currentSummary.posterAppearance
      )
    }
  }

  func removeDirectory(_ identifier: UUID) async throws {
    try await prepare(.remove(identifier))
    lock.withLock {
      currentSummary = ConfigurationSummary(
        directories: currentSummary.directories.filter { $0.id != identifier },
        credentialConfigured: currentSummary.credentialConfigured,
        posterAppearance: currentSummary.posterAppearance
      )
    }
  }

  func reauthorizeDirectory(_ identifier: UUID, _ directory: URL) async throws {
    try await prepare(.reauthorize(identifier, directory))
    lock.withLock {
      let status = ConfiguredDirectoryStatus(
        id: identifier, path: directory.path, availability: .available
      )
      currentSummary = ConfigurationSummary(
        directories: currentSummary.directories.map { $0.id == identifier ? status : $0 },
        credentialConfigured: currentSummary.credentialConfigured,
        posterAppearance: currentSummary.posterAppearance
      )
    }
  }

  func saveCredential(_ value: String) async throws {
    try await prepare(.saveCredential(value))
    lock.withLock {
      currentSummary = ConfigurationSummary(
        directories: currentSummary.directories,
        credentialConfigured: true,
        posterAppearance: currentSummary.posterAppearance
      )
    }
  }

  func setPosterAppearance(_ appearance: PosterAppearance) async throws {
    try await prepare(.setPosterAppearance(appearance))
    lock.withLock {
      currentSummary = ConfigurationSummary(
        directories: currentSummary.directories,
        credentialConfigured: currentSummary.credentialConfigured,
        posterAppearance: appearance
      )
    }
  }

  func removeCredential() async throws {
    try await prepare(.removeCredential)
    lock.withLock {
      currentSummary = ConfigurationSummary(
        directories: currentSummary.directories,
        credentialConfigured: false,
        posterAppearance: currentSummary.posterAppearance
      )
    }
  }

  /// Records a mutating call and waits for the optional operation gate.
  private func prepare(_ call: ConfigurationServiceCall) async throws {
    try record(call)
    await gate?.block()
  }

  /// Records a call or consumes the configured one-shot error.
  private func record(_ call: ConfigurationServiceCall) throws {
    try lock.withLock {
      if let nextError {
        self.nextError = nil
        throw nextError
      }
      recordedCalls.append(call)
    }
  }
}

/// Holds a service operation until a test explicitly opens the gate.
private actor AsyncOperationGate {
  /// Continuation for the operation waiting at the gate.
  private var operationContinuation: CheckedContinuation<Void, Never>?
  /// Continuation for a test waiting until the operation reaches the gate.
  private var entryContinuation: CheckedContinuation<Void, Never>?
  /// Whether the operation has reached the gate at least once.
  private var hasEntered = false

  /// Marks the operation as entered and suspends it until `open()` is called.
  func block() async {
    hasEntered = true
    entryContinuation?.resume()
    entryContinuation = nil
    await withCheckedContinuation { operationContinuation = $0 }
  }

  /// Waits until an operation has reached the gate.
  func waitUntilEntered() async {
    guard !hasEntered else { return }
    await withCheckedContinuation { entryContinuation = $0 }
  }

  /// Resumes an operation suspended by `block()`.
  func open() {
    operationContinuation?.resume()
    operationContinuation = nil
  }
}

/// Verifies that presentation delegates are deduplicated removable and weak.
@MainActor
@Test func presentationDelegatesAreDeduplicatedRemovableAndWeak() async {
  let model = ConfigurationViewModel(service: ConfigurationServiceFake())
  let main = ConfigurationDelegateProbe()
  let settings = ConfigurationDelegateProbe()
  model.addDelegate(main)
  model.addDelegate(main)
  model.addDelegate(settings)
  await model.load()
  #expect(main.updates == 2)
  #expect(settings.updates == main.updates)
  model.removeDelegate(main)
  await model.saveCredential("fake-secret")
  #expect(main.updates == 2)
  #expect(settings.updates == 4)
  weak var released: ConfigurationDelegateProbe?
  do {
    let temporary = ConfigurationDelegateProbe()
    released = temporary
    model.addDelegate(temporary)
    model.activityDelegate = temporary
  }
  #expect(released == nil)
  #expect(model.activityDelegate == nil)
  await model.load()
  #expect(settings.updates == 6)
}

/// Observes configuration state and activity callbacks in presentation tests.
@MainActor
private final class ConfigurationDelegateProbe: ConfigurationViewModelDelegate,
  ConfigurationViewModelActivityDelegate
{
  /// Number of model-state updates received.
  var updates = 0
  /// Activity log used to inspect messages sent by the view model.
  var events: [MovieFolderActivityEvent] = []

  /// Counts a state update from the configuration model.
  func configurationViewModelDidChange(_ viewModel: ConfigurationViewModel) { updates += 1 }
  /// Records activity in the probe's host log.
  func configurationViewModel(
    _ viewModel: ConfigurationViewModel, didRecordActivity event: MovieFolderActivityEvent, saved: Bool
  ) {
    events.append(event)
  }
}

/// Supplies fixed installation evidence to the configuration coordinator tests.
private struct InstallationServiceFake: InstallationReadinessServicing {
  /// Returns deterministic report content without inspecting the host installation.
  func check() async -> InstallationReadinessReport {
    InstallationReadinessReport(text: "Controlled installation evidence")
  }
}

/// Verifies that main keeps settings in their own window and preserves count columns.
@MainActor
@Test func mainKeepsSettingsInTheirOwnWindowAndPreservesCountColumns() async throws {
  let model = ConfigurationViewModel(
    service: ConfigurationServiceFake(
      summary: ConfigurationSummary(
        directories: [.init(id: UUID(), path: "/Movies/Comedy", availability: .available)],
        credentialConfigured: false
      )))
  await model.load()
  let controller = ConfigurationViewController(viewModel: model)
  func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  let views = descendants(controller.view)
  #expect(!views.contains { $0 is NSSecureTextField })
  let table = try #require(views.compactMap { $0 as? NSTableView }.first)
  #expect(
    table.tableColumns.prefix(5).map(\.title) == [
      "Collection", "Done", "Not found", "Several matches", "Total"
    ])
  #expect(
    table.headerView?.accessibilityChildren()?.contains {
      ($0 as? NSButton)?.accessibilityLabel() == "Add collection"
    } == true)
  table.reloadData()
  let cell = try #require(table.view(atColumn: 1, row: 0, makeIfNecessary: true))
  #expect(descendants(cell).compactMap { $0 as? NSTextField }.first?.stringValue == "—")
}

/// Verifies that log is bounded and clear does not change configuration.
@MainActor
@Test func logIsBoundedAndClearDoesNotChangeConfiguration() async {
  let model = ConfigurationViewModel(service: ConfigurationServiceFake())
  await model.saveCredential("fake-secret")
  let log = ActivityLogViewModel(service: ActivityServiceFake())
  for _ in 0..<510 { await log.record(MovieFolderActivityEvent(action: .configurationLoaded, status: .succeeded)) }
  #expect(log.entries.count == 500)
  #expect(log.entries.first?.sequence == 11)
  await log.clear()
  #expect(log.entries.isEmpty)
  #expect(model.credentialConfigured)
}

/// Verifies that activity messages do not expose credentials or underlying errors.
@MainActor
@Test func activityMessagesDoNotExposeCredentialsOrUnderlyingErrors() async {
  let service = ConfigurationServiceFake()
  let model = ConfigurationViewModel(service: service)
  let probe = ConfigurationDelegateProbe()
  model.activityDelegate = probe
  let secret = "fake-sensitive-token"
  service.failNextOperation(with: TestServiceError(message: secret))
  await model.saveCredential(secret)
  #expect(!probe.events.isEmpty)
  #expect(probe.events.allSatisfy { !$0.text.contains(secret) })
  #expect(probe.events.last?.category == "Error")
}

/// Verifies that removing another collection preserves the selected identity.
@MainActor
@Test func removingAnotherCollectionPreservesTheSelectedIdentity() async throws {
  let first = ConfiguredDirectoryStatus(id: UUID(), path: "/Movies/A", availability: .available)
  let second = ConfiguredDirectoryStatus(id: UUID(), path: "/Movies/B", availability: .available)
  let third = ConfiguredDirectoryStatus(id: UUID(), path: "/Movies/C", availability: .available)
  let model = ConfigurationViewModel(
    service: ConfigurationServiceFake(
      summary: ConfigurationSummary(
        directories: [first, second, third], credentialConfigured: false
      )))
  await model.load()
  let controller = ConfigurationViewController(viewModel: model)
  let table = try #require(nativeViews(in: controller.view).compactMap { $0 as? NSTableView }.first)
  table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
  await model.removeDirectory(first.id)
  #expect(model.directories.count == 2)
  #expect(table.selectedRow == 0)
  #expect(model.directories[table.selectedRow].id == second.id)
}

/// Verifies that trailing columns fit with legacy scrollbars.
@MainActor
@Test func trailingColumnsFitWithLegacyScrollbars() throws {
  for width in [680.0, 780.0] {
    let model = ConfigurationViewModel(service: ConfigurationServiceFake())
    let controller = ConfigurationViewController(viewModel: model)
    let window = NSWindow(contentViewController: controller)
    window.setContentSize(NSSize(width: width, height: 310))
    let scroll = try #require(
      nativeViews(in: controller.view).compactMap { $0 as? NSScrollView }.first)
    scroll.scrollerStyle = .legacy
    scroll.autohidesScrollers = false
    controller.view.layoutSubtreeIfNeeded()
    controller.viewDidLayout()
    let table = try #require(scroll.documentView as? NSTableView)
    #expect(table.rect(ofColumn: 5).maxX <= scroll.contentView.bounds.width + 0.5)
  }
  let controller = LogViewController(log: ActivityLogViewModel(service: ActivityServiceFake()))
  let window = NSWindow(contentViewController: controller)
  window.setContentSize(NSSize(width: 650, height: 280))
  let scroll = try #require(
    nativeViews(in: controller.view).compactMap { $0 as? NSScrollView }.first)
  scroll.scrollerStyle = .legacy
  scroll.autohidesScrollers = false
  controller.view.layoutSubtreeIfNeeded()
  controller.viewDidLayout()
  let table = try #require(scroll.documentView as? NSTableView)
  #expect(table.rect(ofColumn: 2).maxX <= scroll.contentView.bounds.width + 0.5)
}

@MainActor
private func nativeViews(in root: NSView) -> [NSView] {
  [root] + root.subviews.flatMap { nativeViews(in: $0) }
}

@Test @MainActor
func settingsShowsThreeLabeledPosterExamplesWithSavedSelection() async throws {
  let service = ConfigurationServiceFake(
    summary: ConfigurationSummary(
      directories: [], credentialConfigured: false, posterAppearance: .matteFrame
    ))
  let model = ConfigurationViewModel(service: service)
  await model.load()
  let settings = SettingsViewController(
    viewModel: model, appearanceSettings: AppAppearanceSettings())
  let pane = try #require(settings.tabViewItems[0].viewController)
  let buttons = nativeViews(in: pane.view).compactMap { $0 as? NSButton }
  for title in ["Raw", "Soft finish", "Matte frame"] {
    let button = try #require(buttons.first { $0.title == title })
    #expect(button.image != nil)
    #expect(button.state == (title == "Matte frame" ? .on : .off))
    #expect(button.accessibilityLabel() == title)
  }
}

@Test @MainActor
func appearanceExamplesApplyAndPersistTheClickedChoice() throws {
  let suite = "AppearancePreviewTests.\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let appearance = AppAppearanceSettings(defaults: defaults)
  let settings = SettingsViewController(
    viewModel: ConfigurationViewModel(service: ConfigurationServiceFake()),
    appearanceSettings: appearance
  )
  let pane = try #require(settings.tabViewItems[2].viewController)
  let buttons = nativeViews(in: pane.view).compactMap { $0 as? NSButton }
  #expect(buttons.map(\.title) == ["System", "Light", "Dark"])
  #expect(buttons.allSatisfy { $0.image != nil })
  let dark = try #require(buttons.first { $0.title == "Dark" })
  dark.performClick(nil)
  #expect(appearance.choice == .dark)
  #expect(AppAppearanceSettings(defaults: defaults).choice == .dark)
  #expect(dark.state == .on)
  #expect(buttons.filter { $0.state == .on }.count == 1)
}

/// Verifies that navigation requests use a weak delegate.
@MainActor
@Test func navigationRequestsUseAWeakDelegate() throws {
  let controller = ConfigurationViewController(
    viewModel: ConfigurationViewModel(service: ConfigurationServiceFake()))
  var delegate: NavigationDelegateProbe? = NavigationDelegateProbe()
  controller.delegate = delegate
  let buttons = nativeViews(in: controller.view).compactMap { $0 as? NSButton }
  try #require(buttons.first { $0.accessibilityLabel() == "Settings" }).performClick(nil)
  try #require(buttons.first { $0.accessibilityLabel() == "Log" }).performClick(nil)
  try #require(buttons.first { $0.title == "Check Installation…" }).performClick(nil)
  #expect(delegate?.requests == ["settings", "log", "installation"])
  #expect(delegate?.lastSender === controller)
  weak var released = delegate
  delegate = nil
  #expect(released == nil)
  #expect(controller.delegate == nil)
}

/// Records navigation requests made by the configuration controller.
@MainActor
private final class NavigationDelegateProbe: ConfigurationViewControllerDelegate {
  /// Ordered navigation destinations requested by the controller.
  var requests: [String] = []
  /// Controller that most recently sent a navigation request.
  weak var lastSender: ConfigurationViewController?
  /// Records a Settings request.
  func configurationViewControllerDidRequestSettings(_ controller: ConfigurationViewController) {
    lastSender = controller
    requests.append("settings")
  }
  /// Records a Log request.
  func configurationViewControllerDidRequestLog(_ controller: ConfigurationViewController) {
    lastSender = controller
    requests.append("log")
  }
  /// Records an installation readiness request.
  func configurationViewControllerDidRequestInstallationReadiness(
    _ controller: ConfigurationViewController
  ) {
    lastSender = controller
    requests.append("installation")
  }
}

/// Verifies that appearance and log delegates notify and release.
@MainActor
@Test func appearanceAndLogDelegatesNotifyAndRelease() async throws {
  let suite = "DelegateAppearanceTests.\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let settings = AppAppearanceSettings(defaults: defaults)
  let log = ActivityLogViewModel(service: ActivityServiceFake())
  var probe: SettingsLogDelegateProbe? = SettingsLogDelegateProbe()
  settings.delegate = probe
  log.delegate = probe
  settings.select(.dark)
  settings.select(.dark)
  await log.record(MovieFolderActivityEvent(action: .applicationOpened, status: .succeeded))
  await log.clear()
  #expect(probe?.appearanceUpdates == 1)
  #expect(probe?.logEntryCounts.contains(1) == true)
  #expect(probe?.logEntryCounts.last == 0)
  #expect(probe?.lastAppearance === settings)
  #expect(probe?.lastLog === log)
  weak var released = probe
  probe = nil
  #expect(released == nil)
  #expect(settings.delegate == nil)
  #expect(log.delegate == nil)
}

/// Records appearance and log delegate callbacks for lifetime tests.
@MainActor
private final class SettingsLogDelegateProbe: AppAppearanceSettingsDelegate, ActivityLogViewModelDelegate {
  /// Number of appearance changes received.
  var appearanceUpdates = 0
  /// Entry counts observed after each log update.
  var logEntryCounts: [Int] = []
  /// Settings object that sent the latest appearance update.
  weak var lastAppearance: AppAppearanceSettings?
  /// Log object that sent the latest update.
  weak var lastLog: ActivityLogViewModel?
  /// Records an appearance change from the settings store.
  func appAppearanceSettingsDidChange(_ settings: AppAppearanceSettings) {
    appearanceUpdates += 1
    lastAppearance = settings
  }
  /// Records the log size after an append or clear operation.
  func activityLogViewModelDidChange(_ log: ActivityLogViewModel) {
    logEntryCounts.append(log.entries.count)
    lastLog = log
  }
}

/// Verifies that main and settings receive shared model updates across visibility changes.
@MainActor
@Test func mainAndSettingsReceiveSharedModelUpdatesAcrossVisibilityChanges() async throws {
  let model = ConfigurationViewModel(service: ConfigurationServiceFake())
  let main = ConfigurationViewController(viewModel: model)
  let table = try #require(nativeViews(in: main.view).compactMap { $0 as? NSTableView }.first)
  let settings = SettingsViewController(
    viewModel: model, appearanceSettings: AppAppearanceSettings())
  _ = settings.view
  settings.selectedTabViewItemIndex = 1
  let pane = try #require(settings.tabViewItems[1].viewController)
  let labels = nativeViews(in: pane.view).compactMap { $0 as? NSTextField }
  let status = try #require(labels.first { $0.stringValue == "Not configured" })
  settings.viewWillAppear()
  settings.viewWillAppear()
  await model.addDirectory(URL(fileURLWithPath: "/Movies"))
  await model.saveCredential("fake-secret")
  #expect(table.numberOfRows == 1)
  #expect(status.stringValue == "Configured")
  settings.viewDidDisappear()
  await model.removeCredential()
  #expect(status.stringValue == "Configured")
  settings.viewWillAppear()
  await model.saveCredential("another-fake-secret")
  await model.removeCredential()
  #expect(status.stringValue == "Not configured")
}

/// Verifies that log controller refreshes for append and clear.
@MainActor
@Test func logControllerRefreshesForAppendAndClear() async throws {
  let log = ActivityLogViewModel(service: ActivityServiceFake())
  let controller = LogViewController(log: log)
  let views = nativeViews(in: controller.view)
  let table = try #require(views.compactMap { $0 as? NSTableView }.first)
  let clear = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == "Clear" })
  #expect(table.numberOfRows == 0)
  #expect(!clear.isEnabled)
  await log.record(MovieFolderActivityEvent(action: .applicationOpened, status: .succeeded))
  #expect(table.numberOfRows == 1)
  #expect(clear.isEnabled)
  clear.performClick(nil)
  while log.canClear { await Task.yield() }
  while log.isClearing || log.isLoading { await Task.yield() }
  #expect(log.entries.isEmpty)
  #expect(table.numberOfRows == 0)
  #expect(!clear.isEnabled)
}

/// Verifies that table deletion and row removal preserve collection identity.
@MainActor
@Test func tableDeletionAndRowRemovalPreserveCollectionIdentity() async throws {
  let first = ConfiguredDirectoryStatus(id: UUID(), path: "/Movies/A", availability: .available)
  let second = ConfiguredDirectoryStatus(id: UUID(), path: "/Movies/B", availability: .available)
  let service = ConfigurationServiceFake(
    summary: ConfigurationSummary(
      directories: [first, second], credentialConfigured: false
    ))
  let model = ConfigurationViewModel(service: service)
  await model.load()
  let controller = ConfigurationViewController(viewModel: model)
  let table = try #require(nativeViews(in: controller.view).compactMap { $0 as? NSTableView }.first)
  // Complete the controller's initial refresh before dispatching another mutation.
  for _ in 0..<100
  where service.calls.filter({ $0 == .configurationSummary }).count < 2 || model.isBusy {
    try await Task.sleep(for: .milliseconds(5))
  }
  let contextClick = try #require(
    NSEvent.mouseEvent(
      with: .rightMouseDown, location: table.convert(NSPoint(x: 10, y: 10), to: nil),
      modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
      eventNumber: 1, clickCount: 1, pressure: 0
    ))
  let menu = try #require(table.menu(for: contextClick))
  let removeItem = try #require(menu.items.first { $0.title == "Remove Collection" })
  #expect(removeItem.representedObject as? UUID == first.id)
  let row = try #require(controller.tableView(table, rowViewForRow: 1))
  let remove = try #require(nativeViews(in: row).compactMap { $0 as? NSButton }.first)
  remove.performClick(nil)
  for _ in 0..<100 where !service.calls.contains(.remove(second.id)) {
    try await Task.sleep(for: .milliseconds(5))
  }
  for _ in 0..<100 where model.isBusy { try await Task.sleep(for: .milliseconds(5)) }
  #expect(model.directories.map(\.id) == [first.id])
  table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
  let delete = try #require(
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}",
      isARepeat: false, keyCode: 51
    ))
  table.keyDown(with: delete)
  for _ in 0..<100 where !service.calls.contains(.remove(first.id)) {
    try await Task.sleep(for: .milliseconds(5))
  }
  for _ in 0..<100 where model.isBusy { try await Task.sleep(for: .milliseconds(5)) }
  #expect(model.directories.isEmpty)
}

/// Coalesces invalidations during a read and keeps the newest committed projection.
@MainActor
@Test func collectionSummaryReloadCoalescesAndDropsSupersededResults() async {
  let rootID = UUID()
  let first = summaryForTesting(rootID: rootID, done: 1, total: 1)
  let latest = summaryForTesting(rootID: rootID, done: 2, total: 2)
  let service = DeferredCollectionSummaryService(responses: [[rootID: first], [rootID: latest]])
  let viewModel = CollectionSummaryViewModel(service: service)

  viewModel.reload()
  await service.waitForCalls(1)
  viewModel.reload()
  viewModel.reload()
  await service.openCall(0)
  await service.waitForCalls(2)
  await service.openCall(1)
  for _ in 0..<100 where viewModel.summary(for: rootID) != latest {
    try? await Task.sleep(for: .milliseconds(5))
  }

  #expect(viewModel.summary(for: rootID) == latest)
  #expect(await service.callCount == 2)
}

/// Shows saved folder evidence in an AppKit details sheet without exposing mutation controls.
@MainActor
@Test func processingDetailsSheetShowsFolderEvidenceAndNoMutationControls() throws {
  let rootID = UUID()
  let processingState = processingStateForTesting(rootID: rootID)
  let summary = CollectionProcessingSummary(
    processingState: processingState,
    presentation: CollectionProcessingPresentation(processingState: processingState),
    counts: processingState.calculateCounts(),
    displayState: .current
  )
  let controller = CollectionProcessingDetailsViewController(
    collectionName: "Movies", summary: summary)
  let views = nativeViews(in: controller.view)
  let text = try #require(views.compactMap { $0 as? NSTextView }.first)

  #expect(text.string.contains("Verified Movie (2024), ID 4242"))
  #expect(text.string.contains("Poster ownership: App-owned"))
  #expect(text.string.contains("Movie identity evidence: Conservative folder-name match"))
  #expect(text.string.contains("Folder identity evidence: Captured"))
  #expect(text.string.contains("Earliest eligible; runs only on later authorized invocation:"))
  #expect(text.string.contains("Last completed collection run:"))
  #expect(text.string.contains("previous processing context") == false)
  #expect(!text.string.contains("folder-identity"))
  #expect(!views.contains { $0 is NSButton })
}

/// Labels a last completed run as historical when it belongs to a prior saved context.
@MainActor
@Test func processingDetailsLabelsHistoricalCompletedRun() throws {
  let initial = processingStateForTesting(rootID: UUID())
  let priorContext = CollectionProcessingContext(
    rootID: initial.context.rootID,
    rootIdentity: initial.context.rootIdentity,
    authorizationVersion: UUID(),
    credentialRevision: UUID(),
    usesStubTMDbResponses: initial.context.usesStubTMDbResponses,
    appearance: initial.context.appearance)
  let processingState = CollectionProcessingState(
    context: initial.context, operation: initial.operation, folders: initial.folders,
    isInventoryComplete: initial.isInventoryComplete, inspectedAt: initial.inspectedAt,
    lastCompletedRun: initial.lastCompletedRun, lastCompletedRunContext: priorContext)
  let summary = CollectionProcessingSummary(
    processingState: processingState, presentation: CollectionProcessingPresentation(processingState: processingState),
    counts: processingState.calculateCounts(), displayState: .current)
  let controller = CollectionProcessingDetailsViewController(collectionName: "Movies", summary: summary)
  let text = try #require(nativeViews(in: controller.view).compactMap { $0 as? NSTextView }.first)

  #expect(text.string.contains("previous processing context"))
}

/// Shows a known inventory Total while keeping unassessed outcome counts unknown.
@MainActor
@Test func partialCollectionCountsKeepKnownTotalIndependent() async throws {
  let rootID = UUID()
  let initial = processingStateForTesting(rootID: rootID)
  let processingState = CollectionProcessingState(
    context: initial.context,
    operation: CollectionProcessingOperation(action: .automatic, startedAt: Date(), state: .partial),
    folders: [FolderProcessingRecord(name: "Pending.Movie", state: .pending)],
    isInventoryComplete: true,
    inspectedAt: Date()
  )
  let summary = CollectionProcessingSummary(
    processingState: processingState,
    presentation: CollectionProcessingPresentation(processingState: processingState),
    counts: processingState.calculateCounts(),
    displayState: .partial
  )
  let directory = ConfiguredDirectoryStatus(
    id: rootID, path: "/Movies", availability: .available)
  let viewModel = ConfigurationViewModel(
    service: ConfigurationServiceFake(
      summary: ConfigurationSummary(directories: [directory], credentialConfigured: false)))
  await viewModel.load()
  let summaryViewModel = CollectionSummaryViewModel(
    service: FixedCollectionSummaryService(summaries: [rootID: summary]))
  summaryViewModel.reload()
  for _ in 0..<100 where summaryViewModel.summary(for: rootID) == nil {
    try await Task.sleep(for: .milliseconds(5))
  }
  let controller = ConfigurationViewController(
    viewModel: viewModel, summaryViewModel: summaryViewModel)
  let table = try #require(nativeViews(in: controller.view).compactMap { $0 as? NSTableView }.first)
  table.reloadData()
  let doneCell = try #require(table.view(atColumn: 1, row: 0, makeIfNecessary: true))
  let totalCell = try #require(table.view(atColumn: 4, row: 0, makeIfNecessary: true))
  let collectionCell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))

  #expect(nativeViews(in: doneCell).compactMap { $0 as? NSTextField }.first?.stringValue == "—")
  #expect(nativeViews(in: totalCell).compactMap { $0 as? NSTextField }.first?.stringValue == "1")
  #expect(
    nativeViews(in: collectionCell).compactMap { $0 as? NSTextField }.contains {
      $0.stringValue.contains("Results: Partial")
    })
}

/// Does not infer an interrupted operation when the coordinated processing state reread fails.
@MainActor
@Test(arguments: [CollectionProcessingError.busy, .unsupportedSchema])
func failedOrphanRereadRemainsUnverified(error: CollectionProcessingError) async throws {
  let temporaryDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
  let configurationRepository = try ConfigurationRepository(
    store: PersistenceStore(directory: temporaryDirectory.appendingPathComponent("Settings")))
  let rootID = UUID()
  let authorizationVersion = UUID()
  var savedConfiguration = DirectoryConfiguration()
  savedConfiguration.directories = [
    MonitoredDirectory(
      id: rootID, path: "/Movies", transferBookmark: Data([1]),
      authorizationVersion: authorizationVersion, identity: "root-identity")
  ]
  try configurationRepository.update { $0 = savedConfiguration }
  let context = CollectionProcessingContext(
    rootID: rootID, rootIdentity: "root-identity",
    authorizationVersion: authorizationVersion,
    credentialRevision: savedConfiguration.credentialRevision,
    usesStubTMDbResponses: false, appearance: .softFinish)
  let running = CollectionProcessingState(
    context: context,
    operation: CollectionProcessingOperation(action: .automatic, startedAt: Date(), state: .running))
  let reader = FailingOrphanReread(processingState: running, failure: error)
  let service = CollectionSummaryService(
    configuration: configurationRepository,
    processingStore: reader,
    coordinationStore: try PersistenceStore(
      directory: temporaryDirectory.appendingPathComponent("ProcessingLocks")))

  let summary = await service.summaries()[rootID]

  let expectedState: CollectionProcessingDisplayState = error == .busy ? .busy : .unavailable
  #expect(summary?.displayState == expectedState)
  #expect(summary?.presentation.state == expectedState)
  #expect(summary?.displayState != .interrupted)
  if error != .busy { #expect(summary?.counts.total == nil) }
  #expect(reader.calls == 2)
  #expect(!reader.wasReadOnMainThread)
}

/// Builds a complete saved collection outcome for presentation tests.
private func processingStateForTesting(rootID: UUID) -> CollectionProcessingState {
  let context = CollectionProcessingContext(
    rootID: rootID, rootIdentity: "root-identity", authorizationVersion: UUID(),
    credentialRevision: UUID(), usesStubTMDbResponses: false, appearance: .softFinish)
  let folder = FolderProcessingRecord(
    name: "Verified.Movie.2024", identity: "folder-identity", state: .done,
    movieID: 4242, movieTitle: "Verified Movie", movieYear: 2024,
    movieIdentitySource: .conservativeMatch,
    ownership: .owned, assessedAt: Date(), retryAt: Date().addingTimeInterval(600),
    lastFailure: FolderProcessingFailure(reason: .timeout, stage: .search, occurredAt: Date()))
  let completed = CollectionProcessingOperation(
    action: .automatic, startedAt: Date().addingTimeInterval(-120),
    endedAt: Date(), state: .completed)

  return CollectionProcessingState(
    context: context, operation: completed, folders: [folder], isInventoryComplete: true,
    inspectedAt: Date(), lastCompletedRun: completed, lastCompletedRunContext: context)
}

/// Creates a collection summary with deterministic headline counts.
private func summaryForTesting(rootID: UUID, done: Int, total: Int) -> CollectionProcessingSummary {
  let processingState = processingStateForTesting(rootID: rootID)
  let counts = CollectionProcessingCounts(done: done, notFound: 0, severalMatches: 0, total: total)

  return CollectionProcessingSummary(
    processingState: processingState,
    presentation: CollectionProcessingPresentation(processingState: processingState),
    counts: counts,
    displayState: .current
  )
}

/// Returns fixed read-only summaries to host presentation tests.
private struct FixedCollectionSummaryService: CollectionSummaryServicing {
  /// Results returned for configured roots.
  let summaries: [UUID: CollectionProcessingSummary]

  /// Returns the configured fixture summaries.
  func summaries() async -> [UUID: CollectionProcessingSummary] { summaries }
}

/// Returns a running processing state once, then simulates contention during its coordinated reread.
private final class FailingOrphanReread: CollectionProcessingStateReading, @unchecked Sendable {
  /// Protects the call count shared by the summary reader's async executor.
  private let lock = NSLock()
  /// Snapshot supplied by the first read.
  private let processingState: CollectionProcessingState
  /// Failure supplied by the coordinated reread.
  private let failure: CollectionProcessingError
  /// Number of processing state reads attempted.
  private var readCount = 0
  /// Whether any synchronous persisted read ran on the main thread.
  private var readOnMainThread = false

  /// Creates a reader that fails after its initial persisted processing state.
  init(processingState: CollectionProcessingState, failure: CollectionProcessingError) {
    self.processingState = processingState
    self.failure = failure
  }

  /// Number of processing state reads attempted.
  var calls: Int { lock.withLock { readCount } }

  /// Whether a read blocked the main thread.
  var wasReadOnMainThread: Bool { lock.withLock { readOnMainThread } }

  /// Returns the initial record and reports contention for the required reread.
  func read(rootID: UUID) throws -> CollectionProcessingState? {
    try lock.withLock {
      readCount += 1
      readOnMainThread = readOnMainThread || Thread.isMainThread
      guard readCount == 1 else { throw failure }
      return processingState
    }
  }
}

/// Holds summary reads until each test explicitly releases them.
private actor DeferredCollectionSummaryService: CollectionSummaryServicing {
  /// Results returned by successive reads.
  private let responses: [[UUID: CollectionProcessingSummary]]
  /// Gates that let the test control completion order.
  private let gates: [SummaryReadGate]
  /// Number of reads started by the model.
  private(set) var callCount = 0

  /// Creates a deferred service with one result and gate per expected read.
  init(responses: [[UUID: CollectionProcessingSummary]]) {
    self.responses = responses
    gates = responses.map { _ in SummaryReadGate() }
  }

  /// Waits for the matching gate, then returns that read's committed result.
  func summaries() async -> [UUID: CollectionProcessingSummary] {
    let index = callCount
    callCount += 1
    await gates[index].wait()

    return responses[index]
  }

  /// Yields until the requested number of summary reads have started.
  func waitForCalls(_ count: Int) async {
    while callCount < count { await Task.yield() }
  }

  /// Releases a specific summary read.
  func openCall(_ index: Int) async { await gates[index].open() }
}

/// Suspends one fake summary read until the test releases it.
private actor SummaryReadGate {
  /// Continuation for the pending service call.
  private var continuation: CheckedContinuation<Void, Never>?
  /// Whether a test opened the gate before the summary read began waiting.
  private var isOpen = false

  /// Suspends until the test opens this gate.
  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { continuation = $0 }
  }

  /// Opens this gate and resumes its pending read.
  func open() {
    isOpen = true
    continuation?.resume()
    continuation = nil
  }
}

/// Logging failure never replaces a successful configuration result.
@MainActor
@Test func configurationResultSurvivesLoggingFailure() async {
  let activity = ActivityServiceFake()
  await activity.setFailures(write: true)
  let model = ConfigurationViewModel(service: ConfigurationServiceFake(), activity: activity)
  await model.saveCredential("private-test-token")
  #expect(model.credentialConfigured)
  #expect(model.errorMessage == nil)
}
