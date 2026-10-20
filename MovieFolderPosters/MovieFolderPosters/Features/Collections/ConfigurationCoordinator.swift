import AppKit
import FinderSync
import MovieFolderCommon

/// Requests routing to an independent sibling flow.
@MainActor
protocol ConfigurationCoordinatorDelegate: AnyObject {
  /// Presents retained activity without coupling configuration to its presentation model.
  func configurationCoordinatorDidRequestLog(_ coordinator: ConfigurationCoordinator)
  /// Invalidates sibling activity presentation after a local write, including unsuccessful writes.
  func configurationCoordinator(_ coordinator: ConfigurationCoordinator, didRecordActivitySaved saved: Bool)
}

/// Owns collection configuration, Settings, and their related picker and report presentations.
@MainActor
final class ConfigurationCoordinator: NSObject, ConfigurationViewControllerDelegate,
  ConfigurationViewModelActivityDelegate {
  /// Root router; the root retains this child for its flow lifetime.
  weak var delegate: (any ConfigurationCoordinatorDelegate)?
  /// Supplies configuration state and operations to the host's views.
  private let viewModel: ConfigurationViewModel
  /// Independently reads committed processing snapshots for main-window presentation.
  private let summaryViewModel: CollectionSummaryViewModel
  /// Shared appearance selection owned and applied by the application root.
  private let appearance: AppAppearanceSettings
  /// The main configuration window, when it has been created.
  private(set) var mainWindow: NSWindowController?
  /// The settings window, when it has been created.
  private(set) var settingsWindow: NSWindowController?
  /// Checks installation evidence when the user requests a readiness report.
  private let installationService: any InstallationReadinessServicing
  /// Whether processing invalidations are registered for this presented flow.
  private var isObservingProcessing = false
  /// Prevents overlapping installation checks and sheets.
  private var checkingInstallation = false

  /// Creates the host flow and connects its configuration and appearance services.
  ///
  /// - Parameters:
  ///   - service: The service used to read and change configured collections.
  ///   - activity: Retained recorder used directly by configuration operations.
  ///   - summaryService: Read-only committed processing projections for Main.
  ///   - appearance: Root-owned preferences shared with Settings.
  ///   - installationService: The provider used to inspect installation evidence.
  init(
    service: any ConfigurationServicing,
    activity: any MovieFolderActivityServicing = MovieFolderEnvironment.makeActivityRecorder(),
    summaryService: any CollectionSummaryServicing = EmptyCollectionSummaryService(),
    appearance: AppAppearanceSettings = AppAppearanceSettings(),
    installationService: any InstallationReadinessServicing = InstallationReadinessService(),
    recovery: ProcessingRecoveryService? = .none
  ) {
    self.installationService = installationService
    self.appearance = appearance
    viewModel = ConfigurationViewModel(service: service, activity: activity, recovery: recovery)
    summaryViewModel = CollectionSummaryViewModel(service: summaryService)
    super.init()
    viewModel.activityDelegate = self
  }

  deinit {
    DistributedNotificationCenter.default().removeObserver(self)
  }

  /// Creates or presents the main configuration window.
  func start() {
    if !isObservingProcessing {
      isObservingProcessing = true
      DistributedNotificationCenter.default().addObserver(
        self, selector: #selector(processingChanged(_:)),
        name: MovieFolderEnvironment.collectionProcessingStateChanged, object: .none)
    }
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
    Task { await viewModel.reloadRecoveryMode() }
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

  /// Checks installation evidence and presents the report in a sheet.
  private func showInstallationReadiness() {
    guard !checkingInstallation, !viewModel.isBusy, let window = mainWindow?.window,
      window.attachedSheet == .none
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
      guard window.isVisible, window.attachedSheet == .none else { return }
      let reportController = InstallationReadinessViewController(report: report)
      let alert = NSAlert()
      alert.messageText = "Installation Readiness"
      alert.informativeText = "Checks describe current evidence. Unknown states require further verification."
      alert.accessoryView = reportController.view
      alert.addButton(withTitle: "Done")
      alert.addButton(withTitle: "Open Extension Settings")
      alert.beginSheetModal(for: window) { response in
        if response == .alertSecondButtonReturn { FIFinderSyncController.showExtensionManagementInterface() }
      }
    }
  }

  /// Shows the selected collection's read-only persisted details as a window sheet.
  private func showProcessingDetails(rootID: UUID) {
    guard let window = mainWindow?.window, window.attachedSheet == .none,
      let directory = viewModel.directories.first(where: { $0.id == rootID })
    else { return }
    let summary = summaryViewModel.summary(for: rootID) ?? CollectionProcessingSummary(
      processingState: .none,
      presentation: CollectionProcessingPresentation(processingState: .none),
      counts: CollectionProcessingCounts(done: .none, notFound: .none, severalMatches: .none, total: .none),
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
    window.beginSheet(sheet, completionHandler: .none)
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
    window.center()

    return NSWindowController(window: window)
  }

  /// Presents a window and brings it to the front.
  ///
  /// - Parameter controller: The window controller to display.
  private func show(_ controller: NSWindowController) {
    controller.showWindow(.none)
    controller.window?.makeKeyAndOrderFront(.none)
  }

  /// Responds to the configuration view's request to open Settings.
  ///
  /// - Parameter controller: The view controller that sent the request.
  func configurationViewControllerDidRequestSettings(_ controller: ConfigurationViewController) { showSettings() }
  /// Responds to the configuration view's request to open the activity log.
  ///
  /// - Parameter controller: The view controller that sent the request.
  func configurationViewControllerDidRequestLog(_ controller: ConfigurationViewController) {
    delegate?.configurationCoordinatorDidRequestLog(self)
  }

  /// Reports local persistence results without depending on the sibling Log's presentation state.
  func configurationViewModel(
    _ viewModel: ConfigurationViewModel, didRecordActivity event: MovieFolderActivityEvent, saved: Bool
  ) {
    delegate?.configurationCoordinator(self, didRecordActivitySaved: saved)
  }
  /// Responds to a request to show installation evidence.
  ///
  /// - Parameter controller: The view controller that sent the request.
  func configurationViewControllerDidRequestInstallationReadiness(_ controller: ConfigurationViewController) {
    showInstallationReadiness()
  }

  /// Responds to a request for a collection's saved processing details.
  func configurationViewControllerDidRequestProcessingDetails(_ controller: ConfigurationViewController, rootID: UUID) {
    showProcessingDetails(rootID: rootID)
  }

  /// Reloads committed projections after an external change without retaining notification payloads.
  @objc private func processingChanged(_ notification: Notification) {
    Task { @MainActor [weak self] in self?.refreshCollectionProcessingState() }
  }

  /// Owns folder selection and applies only a confirmed selection through the configuration model.
  func configurationViewController(
    _ controller: ConfigurationViewController, didRequestDirectorySelection identifier: UUID?
  ) {
    guard !viewModel.isBusy, let window = mainWindow?.window, window.attachedSheet == .none else { return }
    let panel = NSOpenPanel()
    panel.title = identifier == .none ? "Choose Movie Folder" : "Restore Folder Access"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      Task {
        if let identifier {
          await self.viewModel.reauthorizeDirectory(identifier, with: url)
        } else {
          await self.viewModel.addDirectory(url)
        }
      }
    }
  }
}
