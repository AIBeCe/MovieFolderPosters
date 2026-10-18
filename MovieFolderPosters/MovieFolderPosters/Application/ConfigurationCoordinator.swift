import MovieFolderCommon
import AppKit
import FinderSync

/// Owns configuration-window presentation and coordinates host-level services.
@MainActor
final class ConfigurationCoordinator: ConfigurationViewControllerDelegate,
  ConfigurationViewModelActivityDelegate,
  AppAppearanceSettingsDelegate
{
  /// Supplies configuration state and operations to the host's views.
  private let viewModel: ConfigurationViewModel
  /// Independently reads committed processing snapshots for main-window presentation.
  private let summaryViewModel: CollectionSummaryViewModel
  /// Stores and publishes the app-wide appearance selection.
  private let appearance = AppAppearanceSettings()
  /// Retains recent host activity for the log window.
  private let log: ActivityLogViewModel
  /// Payload-free committed activity invalidation observer.
  private var activityObserver: NSObjectProtocol?
  /// The main configuration window, when it has been created.
  private var mainWindow: NSWindowController?
  /// The settings window, when it has been created.
  private var settingsWindow: NSWindowController?
  /// The activity log window, when it has been created.
  private var logWindow: NSWindowController?
  /// Checks installation evidence when the user requests a readiness report.
  private let installationService: any InstallationReadinessServicing
  /// Repository used for normal startup and root-removal cleanup.
  private let processingStore: CollectionProcessingStore?
  /// Observer token for committed result changes from Finder or host actions.
  private var processingObserver: NSObjectProtocol?
  /// Prevents overlapping installation checks and sheets.
  private var checkingInstallation = false

  /// Creates the host flow and connects its configuration and appearance services.
  ///
  /// - Parameters:
  ///   - service: The service used to read and change configured collections.
  ///   - installationService: The provider used to inspect installation evidence.
  init(
    service: any ConfigurationServicing,
    activity: any MovieFolderActivityServicing = MovieFolderEnvironment.makeActivityRecorder(),
    summaryService: any CollectionSummaryServicing = EmptyCollectionSummaryService(),
    processingStore: CollectionProcessingStore? = nil,
    installationService: any InstallationReadinessServicing = InstallationReadinessService()
  ) {
    self.installationService = installationService
    self.processingStore = processingStore
    log = ActivityLogViewModel(service: activity)
    viewModel = ConfigurationViewModel(service: service, activity: activity)
    summaryViewModel = CollectionSummaryViewModel(service: summaryService)
    viewModel.activityDelegate = self
    appearance.delegate = self
    activityObserver = DistributedNotificationCenter.default().addObserver(
      forName: MovieFolderEnvironment.activityChanged, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.log.requestReload() }
    }
    processingObserver = DistributedNotificationCenter.default().addObserver(
      forName: MovieFolderEnvironment.collectionProcessingStateChanged, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.refreshCollectionProcessingState() }
    }
  }

  /// Creates or presents the main configuration window.
  func start() {
    if let mainWindow {
      refreshCollectionProcessingState()
      show(mainWindow)
      return
    }
    let controller = ConfigurationViewController(
      viewModel: viewModel, summaryViewModel: summaryViewModel)
    controller.delegate = self
    let window = makeWindow(
      title: "Movie Folder Posters", controller: controller,
      size: NSSize(width: 780, height: 310), minimum: NSSize(width: 680, height: 260))
    mainWindow = window
    show(window)
  }

  /// Reloads processing states after the app becomes active without rereading settings.
  func applicationDidBecomeActive() {
    refreshCollectionProcessingState()
    log.requestReload()
  }

  /// Requests a summary-only reload after an outcome notification or explicit app activation.
  func refreshCollectionProcessingState() { summaryViewModel.reload() }

  /// Creates or presents Settings and refreshes the displayed configuration.
  func showSettings() {
    if let settingsWindow {
      show(settingsWindow)
    } else {
      let controller = SettingsViewController(viewModel: viewModel, appearanceSettings: appearance)
      let window = makeWindow(
        title: "Settings", controller: controller,
        size: NSSize(width: 640, height: 420), minimum: NSSize(width: 640, height: 420))
      window.window?.toolbarStyle = .preference
      settingsWindow = window
      show(window)
    }
    Task { await viewModel.load() }
  }

  /// Creates or presents the activity log window.
  func showLog() {
    log.requestReload()
    if let logWindow {
      show(logWindow)
      return
    }
    let controller = LogViewController(log: log)
    let window = makeWindow(
      title: "Log — Movie Folder Posters", controller: controller,
      size: NSSize(width: 820, height: 360), minimum: NSSize(width: 650, height: 280))
    logWindow = window
    show(window)
  }

  /// Checks installation evidence and presents the report in a sheet.
  private func showInstallationReadiness() {
    guard !checkingInstallation, !viewModel.isBusy, let window = mainWindow?.window,
      window.attachedSheet == nil
    else { return }
    checkingInstallation = true
    Task { [weak self] in
      guard let self else { return }
      guard !viewModel.isBusy else {
        checkingInstallation = false
        return
      }
      let report = await installationReport()
      checkingInstallation = false
      guard window.isVisible, window.attachedSheet == nil else { return }
      let alert = NSAlert()
      alert.messageText = "Installation Readiness"
      alert.informativeText =
        "Checks describe current evidence. Unknown states require further verification."
      let details = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))
      details.hasVerticalScroller = true
      details.borderType = .bezelBorder
      let text = NSTextView(frame: details.bounds)
      text.isEditable = false
      text.isSelectable = true
      text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
      text.isVerticallyResizable = true
      text.isHorizontallyResizable = false
      text.autoresizingMask = [.width]
      text.textContainer?.widthTracksTextView = true
      text.textContainerInset = NSSize(width: 8, height: 8)
      text.setAccessibilityLabel("Installation readiness details")
      text.string =
        report.text + "\n\nIf posters do not update: Refresh Status, restore folder "
        + "access if requested, confirm a token is configured in Settings, then close all Finder views "
        + "of the collection and reopen it. Enabling the extension does not grant folder access."
      details.documentView = text
      alert.accessoryView = details
      alert.addButton(withTitle: "Done")
      alert.addButton(withTitle: "Open Extension Settings")
      alert.beginSheetModal(for: window) { response in
        if response == .alertSecondButtonReturn {
          FIFinderSyncController.showExtensionManagementInterface()
        }
      }
    }
  }

  /// Shows the selected collection's read-only persisted details as a window sheet.
  private func showProcessingDetails(rootID: UUID) {
    guard let window = mainWindow?.window, window.attachedSheet == nil,
      let directory = viewModel.directories.first(where: { $0.id == rootID })
    else { return }
    let summary = summaryViewModel.summary(for: rootID) ?? CollectionProcessingSummary(
      processingState: nil,
      presentation: CollectionProcessingPresentation(processingState: nil),
      counts: CollectionProcessingCounts(done: nil, notFound: nil, severalMatches: nil, total: nil),
      displayState: .unavailable
    )
    let controller = CollectionProcessingDetailsViewController(
      collectionName: URL(fileURLWithPath: directory.path).lastPathComponent,
      summary: summary)
    let sheet = NSWindow(contentViewController: controller)
    sheet.title = "Processing Details — \(URL(fileURLWithPath: directory.path).lastPathComponent)"
    sheet.styleMask = [.titled, .closable, .resizable]
    sheet.setContentSize(NSSize(width: 680, height: 520))
    sheet.minSize = NSSize(width: 560, height: 360)
    window.beginSheet(sheet, completionHandler: nil)
  }

  /// Prunes records made orphaned by a completed root removal.
  func configurationViewControllerDidRemoveCollectionRoot(_ controller: ConfigurationViewController) {
    guard let processingStore else { return }
    Task { @MainActor [weak self] in
      let cleanupSucceeded = await Task.detached {
        do {
          _ = try processingStore.pruneToConfiguredRoots()
          return true
        } catch {
          return false
        }
      }.value
      if !cleanupSucceeded {
        await self?.log.record(MovieFolderActivityEvent(action: .collectionCleanup, status: .failed))
      }
    }
  }

  /// Combines installation evidence with the last-loaded setup summary.
  ///
  /// - Returns: The report text shown by the readiness sheet.
  func installationReport() async -> InstallationReadinessReport {
    let setup = viewModel.installationSetupDescription
    let report = await installationService.check()

    return InstallationReadinessReport(text: report.text + "\n\n" + setup)
  }

  /// Builds a centered, resizable window for a configuration view controller.
  ///
  /// - Parameters:
  ///   - title: The title displayed in the window's title bar.
  ///   - controller: The view controller installed as the window content.
  ///   - size: The initial content size.
  ///   - minimum: The smallest permitted content size.
  /// - Returns: A window controller retaining the configured window.
  private func makeWindow(
    title: String, controller: NSViewController, size: NSSize,
    minimum: NSSize
  ) -> NSWindowController {
    let window = NSWindow(contentViewController: controller)
    window.title = title
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.setContentSize(size)
    window.minSize = minimum
    window.isReleasedWhenClosed = false
    window.appearance = AppAppearanceSettings.appearance(for: appearance.choice)
    window.center()

    return NSWindowController(window: window)
  }

  /// Presents a window and brings it to the front.
  ///
  /// - Parameter controller: The window controller to display.
  private func show(_ controller: NSWindowController) {
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }

  /// Responds to the configuration view's request to open Settings.
  ///
  /// - Parameter controller: The view controller that sent the request.
  func configurationViewControllerDidRequestSettings(_ controller: ConfigurationViewController) {
    showSettings()
  }
  /// Responds to the configuration view's request to open the activity log.
  ///
  /// - Parameter controller: The view controller that sent the request.
  func configurationViewControllerDidRequestLog(_ controller: ConfigurationViewController) {
    showLog()
  }
  /// Responds to a request to show installation evidence.
  ///
  /// - Parameter controller: The view controller that sent the request.
  func configurationViewControllerDidRequestInstallationReadiness(
    _ controller: ConfigurationViewController
  ) {
    showInstallationReadiness()
  }

  /// Responds to a request for a collection's saved processing details.
  func configurationViewControllerDidRequestProcessingDetails(
    _ controller: ConfigurationViewController, rootID: UUID
  ) {
    showProcessingDetails(rootID: rootID)
  }

  /// Adds view-model activity entries to the host activity log.
  ///
  /// - Parameters:
  ///   - viewModel: The model that recorded the activity.
  ///   - event: Typed product outcome.
  ///   - saved: Whether the independent logging write succeeded.
  func configurationViewModel(
    _ viewModel: ConfigurationViewModel, didRecordActivity event: MovieFolderActivityEvent, saved: Bool
  ) {
    log.producerDidRecord(saved: saved)
  }

  /// Applies an updated app appearance to all windows.
  ///
  /// - Parameter settings: The settings object that changed.
  func appAppearanceSettingsDidChange(_ settings: AppAppearanceSettings) { applyAppearance() }

  /// Updates existing windows to use the selected appearance and records the change.
  private func applyAppearance() {
    for controller in [mainWindow, settingsWindow, logWindow] {
      controller?.window?.appearance = AppAppearanceSettings.appearance(for: appearance.choice)
    }
    Task { await log.record(MovieFolderActivityEvent(action: .applicationAppearanceChanged, status: .succeeded)) }
  }
}
