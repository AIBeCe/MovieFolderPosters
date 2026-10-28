import AppKit
import FinderSync
import MovieFolderCommon
import UniformTypeIdentifiers

/// Requests routing to an independent sibling flow.
@MainActor
protocol ConfigurationCoordinatorDelegate: AnyObject {
  /// Presents retained activity without coupling configuration to its presentation model.
  func configurationCoordinatorDidRequestLog(_ coordinator: ConfigurationCoordinator)
  /// Invalidates sibling activity presentation after a local write, including unsuccessful writes.
  func configurationCoordinator(_ coordinator: ConfigurationCoordinator, didRecordActivitySaved saved: Bool)
  /// Requests explicit selection in the existing poster-action flow attached to results.
  func configurationCoordinator(
    _ coordinator: ConfigurationCoordinator, didRequestPosterAction request: MoviePosterRequest,
    attachedTo parent: NSWindow)
  /// Cancels the nested selection flow before its owning results sheet closes.
  func configurationCoordinator(_ coordinator: ConfigurationCoordinator, willCloseResults window: NSWindow)
}

/// Keeps read-only hosts independent of optional resolution presentation.
extension ConfigurationCoordinatorDelegate {
  func configurationCoordinator(
    _ coordinator: ConfigurationCoordinator, didRequestPosterAction request: MoviePosterRequest,
    attachedTo parent: NSWindow) {}
  func configurationCoordinator(_ coordinator: ConfigurationCoordinator, willCloseResults window: NSWindow) {}
}

/// Owns collection configuration, Settings, and their related picker and report presentations.
@MainActor
final class ConfigurationCoordinator: NSObject, ConfigurationViewControllerDelegate,
  ConfigurationViewModelActivityDelegate, CollectionProcessingDetailsViewControllerDelegate,
  CollectionResultsViewControllerDelegate, NSWindowDelegate, LocalDataPaneDelegate,
  LocalDataExportCoordinatorDelegate {
  /// Root router; the root retains this child for its flow lifetime.
  weak var delegate: (any ConfigurationCoordinatorDelegate)?
  /// Supplies configuration state and operations to the host's views.
  let viewModel: ConfigurationViewModel
  /// Retains the persistence boundary for confirmed Finder inclusion actions.
  let service: any ConfigurationServicing
  /// Independently reads saved processing summaries for the main window.
  let summaryViewModel: CollectionSummaryViewModel
  /// Shared appearance selection owned and applied by the application root.
  private let appearance: AppAppearanceSettings
  /// The main configuration window, when it has been created.
  private(set) var mainWindow: NSWindowController?
  /// The settings window, when it has been created.
  private(set) var settingsWindow: NSWindowController?
  /// Dedicated Local Data window, reused until the user closes it.
  private(set) var localDataWindow: NSWindowController?
  /// Retains the finite local data export flow until dismissal or parent closure.
  private var localDataExportCoordinator: LocalDataExportCoordinator?
  /// Fences readiness preparation after either owning window closes.
  private var localDataExportPreparationRequestID = UInt64.zero
  /// Window whose asynchronous readiness evidence is being prepared.
  private weak var localDataExportPreparationParent: NSWindow?
  /// Window that owns the current finite export sheet, if any.
  private(set) weak var localDataExportParent: NSWindow?
  /// Read-only source shared between local storage presentation and local data export.
  private var localDataExportService: any LocalDataExportServicing { LocalDataExportService(activity: activity) }
  /// Retained history provider used only after an explicit diagnostic export request.
  private let activity: any MovieFolderActivityServicing
  /// Checks installation evidence when the user requests a readiness report.
  private let installationService: any InstallationReadinessServicing
  /// Whether processing invalidations are registered for this presented flow.
  private var isObservingProcessing = false
  /// Prevents overlapping installation checks and sheets.
  private var checkingInstallation = false
  /// Shared host admission service used by selected retries.
  private let retryService: any CollectionRetryServicing
  /// Processing-details sheet retained until explicit dismissal or parent closure.
  private var detailsWindow: NSWindow?
  /// Fences delayed Finder presentation after closing Main or replacing the request.
  private var contextMenuPresentationGeneration: UInt64 = .zero
  /// Live inspection effect owner retained through its sheet.
  private var detailsViewModel: CollectionProcessingDetailsViewModel?
  /// Read-only utility admission and immediate platform boundary.
  private let utilityService: any MovieFolderFinderActionServicing
  /// Immediate native effect adapter owned for the lifetime of configuration sheets.
  private let utilityPlatform: any MovieFolderUtilityPlatform
  /// Results presentation retained until explicit dismissal or parent closure.
  private(set) var resultsWindow: NSWindow?
  /// Owns selected retry lifetime independently of view rendering.
  private var resultsViewModel: CollectionResultsViewModel?
  /// Finite setup sheet retained independently from Settings and result sheets.
  var setupWindow: NSWindow?
  /// Uncommitted bookmarks and local choices, discarded with the setup sheet.
  var setupViewModel: CollectionSetupViewModel?
  /// Retains the finite collection edit sheet until cancellation or a successful atomic save.
  var editWindow: NSWindow?
  /// Draft and compare-and-swap evidence owned by the edit flow.
  var editViewModel: CollectionEditViewModel?

  /// Creates the host flow and connects its configuration and appearance services.
  ///
  /// - Parameters:
  ///   - service: The service used to read and change configured collections.
  ///   - activity: Retained recorder used directly by configuration operations.
  ///   - summaryService: Read-only committed processing projections for Main.
  ///   - appearance: Root-owned preferences shared with Settings.
  ///   - installationService: The provider used to inspect installation evidence.
  ///   - recovery: Shared recovery admission used by explicit retry and configuration actions.
  ///   - retryService: Shared bounded retry service used by unresolved results.
  init(
    service: any ConfigurationServicing,
    activity: any MovieFolderActivityServicing = MovieFolderEnvironment.makeActivityRecorder(),
    summaryService: any CollectionSummaryServicing = EmptyCollectionSummaryService(),
    appearance: AppAppearanceSettings = AppAppearanceSettings(),
    installationService: any InstallationReadinessServicing = InstallationReadinessService(),
    recovery: ProcessingRecoveryService? = .none,
    retryService: any CollectionRetryServicing = UnavailableCollectionRetryService(),
    utilityService: any MovieFolderFinderActionServicing = MovieFolderFinderActionService(),
    utilityPlatform: any MovieFolderUtilityPlatform = SystemMovieFolderUtilityPlatform()
  ) {
    self.service = service
    self.installationService = installationService
    self.activity = activity
    self.appearance = appearance
    self.retryService = retryService
    self.utilityService = utilityService
    self.utilityPlatform = utilityPlatform
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
    observeConfigurationChanges()
    if let mainWindow {
      mainWindow.window?.delegate = self
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
    window.window?.delegate = self
    show(window)
  }

  /// Observes shared invalidations while Main, Settings, or Local Data uses this retained flow.
  private func observeConfigurationChanges() {
    if !isObservingProcessing {
      isObservingProcessing = true
      DistributedNotificationCenter.default().addObserver(
        self, selector: #selector(processingChanged(_:)),
        name: .movieFolderCollectionProcessingStateChanged, object: .none)
      DistributedNotificationCenter.default().addObserver(
        self, selector: #selector(resultsConfigurationChanged(_:)),
        name: .movieFolderConfigurationChanged, object: .none)
      DistributedNotificationCenter.default().addObserver(
        self, selector: #selector(collectionPresentationChanged(_:)),
        name: .movieFolderCollectionPresentationChanged, object: .none)
    }
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
    observeConfigurationChanges()
    if let settingsWindow {
      show(settingsWindow)
    } else {
      let controller = SettingsViewController(viewModel: viewModel, appearanceSettings: appearance)
      controller.credentialDelegate = self
      let window = makeWindow(
        title: "Settings", controller: controller,
        size: NSSize(width: 700, height: 650), minimum: NSSize(width: 700, height: 650))
      window.window?.toolbarStyle = .preference
      window.window?.delegate = self
      settingsWindow = window
      show(window)
    }
    Task { await viewModel.load() }
  }

  /// Creates or fronts the dedicated Local Data window and its reusable pane.
  func showLocalData() {
    observeConfigurationChanges()
    if let localDataWindow {
      show(localDataWindow)
      return
    }
    let controller = LocalDataPane(service: localDataExportService)
    controller.delegate = self
    let window = makeWindow(
      title: "Local Data", controller: controller,
      size: NSSize(width: 700, height: 650), minimum: NSSize(width: 700, height: 650))
    window.window?.delegate = self
    localDataWindow = window
    show(window)
  }

  /// Shows the selected collection's read-only persisted details as a window sheet.
  private func showProcessingDetails(rootID: UUID, request: MovieFolderContextMenuRequest? = .none) {
    guard let window = mainWindow?.window, window.attachedSheet == .none,
      let directory = viewModel.directories.first(where: { $0.id == rootID })
    else { return }
    let summary = summaryViewModel.summary(for: rootID) ?? CollectionProcessingSummary(
      processingState: .none,
      presentation: CollectionProcessingPresentation(processingState: .none),
      counts: CollectionProcessingCounts(done: .none, notFound: .none, severalMatches: .none, total: .none),
      displayState: .unavailable
    )
    guard let request = request ?? (try? MovieFolderContextMenuRequest(rootID: rootID,
      target: .collection, action: .inspect)) else { return }
    let model = CollectionProcessingDetailsViewModel(request: request, summaries: summaryViewModel,
      utilities: utilityService, platform: utilityPlatform)
    detailsViewModel = model
    let controller = CollectionProcessingDetailsViewController(
      collectionName: directory.effectiveDisplayName,
      summary: summary, viewModel: model)
    controller.delegate = self
    let sheet = NSWindow(contentViewController: controller)
    sheet.title = "Processing Details — \(directory.effectiveDisplayName)"
    sheet.contentView?.toolTip = directory.path
    sheet.styleMask = [.titled, .closable, .resizable]
    sheet.setContentSize(NSSize(width: 680, height: 520))
    sheet.minSize = NSSize(width: 560, height: 360)
    sheet.delegate = self
    detailsWindow = sheet
    window.beginSheet(sheet, completionHandler: .none)
    model.reload()
  }

  /// Routes Finder inspection without automatically invoking Copy or provider work.
  func showProcessingDetails(for request: MovieFolderContextMenuRequest) {
    start()
    contextMenuPresentationGeneration &+= 1
    let generation = contextMenuPresentationGeneration
    Task { [weak self] in
      guard let self else { return }

      await viewModel.load()

      guard contextMenuPresentationGeneration == generation, mainWindow?.window?.isVisible == true else { return }

      showLoadedProcessingDetails(for: request)
    }
  }

  /// Presents a validated target after the configured roots have loaded.
  private func showLoadedProcessingDetails(for request: MovieFolderContextMenuRequest) {
    guard !viewModel.isBusy, let window = mainWindow?.window else { return }

    if let current = detailsViewModel, current.request.target == request.target,
      current.request.rootID == request.rootID, !current.isBusy {
      detailsWindow?.makeKeyAndOrderFront(.none)
      (detailsWindow?.contentViewController as? CollectionProcessingDetailsViewController)?.focus(request.action)
      current.reload()
      return
    }
    if let current = detailsViewModel, !current.isBusy { closeDetails() }

    guard detailsWindow == .none, resultsWindow == .none, setupWindow == .none, editWindow == .none,
      window.attachedSheet == .none else {
      let alert = NSAlert()
      alert.messageText = "Close the current sheet before inspecting another folder."
      alert.runModal()
      return
    }
    showProcessingDetails(rootID: request.rootID, request: request)
  }

  /// Ends the processing-details sheet when its Close action or parent window dismisses it.
  private func closeDetails() {
    guard let sheet = detailsWindow else { return }
    detailsViewModel?.invalidate()
    detailsViewModel = .none
    detailsWindow = .none
    if let parent = sheet.sheetParent { parent.endSheet(sheet) }
    sheet.delegate = .none
    sheet.close()
  }

  /// Opens a finite results sheet; reading its evidence never requests provider work.
  /// - Parameter rootID: Configured collection selected in Main.
  private func showUnresolvedResults(rootID: UUID) {
    guard let parent = mainWindow?.window, parent.attachedSheet == .none, !viewModel.isBusy,
      let directory = viewModel.directories.first(where: { $0.id == rootID })
    else { return }
    let model = CollectionResultsViewModel(rootID: rootID, summaries: summaryViewModel, retryService: retryService,
      utilityService: utilityService, utilityPlatform: utilityPlatform)
    let controller = CollectionResultsViewController(viewModel: model)
    controller.delegate = self
    let sheet = NSWindow(contentViewController: controller)
    sheet.title = "Unresolved Results — \(directory.effectiveDisplayName)"
    sheet.contentView?.toolTip = directory.path
    sheet.styleMask = [.titled, .closable, .resizable]
    sheet.setContentSize(NSSize(width: 800, height: 480))
    sheet.minSize = NSSize(width: 680, height: 360)
    sheet.delegate = self
    resultsWindow = sheet
    resultsViewModel = model
    parent.beginSheet(sheet)
    model.reload()
  }

  /// Cancels outstanding work and dismisses only the results flow's own child sheets.
  private func closeResults() {
    guard let sheet = resultsWindow else { return }
    resultsWindow = .none
    resultsViewModel?.cancelRetryTask()
    delegate?.configurationCoordinator(self, willCloseResults: sheet)
    if let parent = sheet.sheetParent { parent.endSheet(sheet) }
    sheet.delegate = .none
    sheet.close()
    resultsViewModel = .none
    summaryViewModel.reload()
  }

  /// Prevents results work from outliving either its own sheet or Main.
  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    if window === mainWindow?.window {
      cancelLocalDataExport(attachedTo: window)
      contextMenuPresentationGeneration &+= 1
      if settingsWindow?.window?.isVisible != true && localDataWindow?.window?.isVisible != true {
        DistributedNotificationCenter.default().removeObserver(self)
        isObservingProcessing = false
      }
      window.delegate = .none
      closeDetails()
      closeResults()
      closeSetup()
      closeEdit()
    } else if window === settingsWindow?.window {
      cancelLocalDataExport(attachedTo: window)
      viewModel.cancelCredentialAction()
      if mainWindow?.window?.isVisible != true && localDataWindow?.window?.isVisible != true {
        DistributedNotificationCenter.default().removeObserver(self)
        isObservingProcessing = false
      }
    } else if window === localDataWindow?.window {
      cancelLocalDataExport(attachedTo: window)
      localDataWindow = nil
      if mainWindow?.window?.isVisible != true && settingsWindow?.window?.isVisible != true {
        DistributedNotificationCenter.default().removeObserver(self)
        isObservingProcessing = false
      }
    } else if window === detailsWindow {
      closeDetails()
    } else if window === resultsWindow {
      closeResults()
    } else if window === setupWindow {
      closeSetup()
    } else if window === editWindow {
      closeEdit()
    }
  }

  /// Dismisses the details sheet through its owning coordinator.
  func collectionProcessingDetailsViewControllerDidRequestClose(
    _ controller: CollectionProcessingDetailsViewController
  ) { closeDetails() }

  /// Forwards an explicit row action to the application-owned Choose Movie flow.
  func collectionResultsViewController(
    _ controller: CollectionResultsViewController, didRequestMovieSelection request: MoviePosterRequest
  ) {
    guard let parent = resultsWindow, parent.attachedSheet == .none else { return }
    delegate?.configurationCoordinator(self, didRequestPosterAction: request, attachedTo: parent)
  }

  /// Ends the results presentation after its Done action.
  func collectionResultsViewControllerDidRequestClose(_ controller: CollectionResultsViewController) { closeResults() }

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
  /// Responds to the configuration view's request to open Local Data.
  func configurationViewControllerDidRequestLocalData(_ controller: ConfigurationViewController) { showLocalData() }
  /// Responds to the configuration view's request to open the activity log.
  ///
  /// - Parameter controller: The view controller that sent the request.
  func configurationViewControllerDidRequestLog(_ controller: ConfigurationViewController) {
    delegate?.configurationCoordinatorDidRequestLog(self)
  }

  /// Reports local persistence results without depending on the sibling Log's presentation state.
  func configurationViewModel(
    _ viewModel: ConfigurationViewModel, didRecordActivity event: MovieFolderActivityLogEvent, saved: Bool
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

  /// Presents focused unresolved results for a configured collection.
  func configurationViewControllerDidRequestUnresolvedResults(_ controller: ConfigurationViewController, rootID: UUID) {
    showUnresolvedResults(rootID: rootID)
  }

  /// Invalidates captured selection after authorization or processing configuration changes.
  @objc private func resultsConfigurationChanged(_ notification: Notification) {
    Task { @MainActor [weak self] in
      self?.contextMenuPresentationGeneration &+= 1
      self?.detailsViewModel?.invalidate()
      self?.resultsViewModel?.configurationDidChange()
      self?.summaryViewModel.reload()
      self?.viewModel.invalidateCredentialState()
      await self?.viewModel.reloadCredentialState(clearResult: false)
    }
  }

  /// Reloads committed projections after an external change without retaining notification payloads.
  @objc private func processingChanged(_ notification: Notification) {
    Task { @MainActor [weak self] in self?.refreshCollectionProcessingState() }
  }

}

private extension ConfigurationCoordinator {
  /// Checks installation evidence and presents the report in a sheet.
  func showInstallationReadiness() {
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
      alert.addButton(withTitle: "Export Diagnostics…")
      alert.beginSheetModal(for: window) { response in
        if response == .alertSecondButtonReturn { FIFinderSyncController.showExtensionManagementInterface() }
        if response == .alertThirdButtonReturn {
          self.exportDiagnostics(report: report, attachedTo: window)
        }
      }
    }
  }

  /// Replaces the old immediate save route with explicit evidence selection and exact preview.
  func exportDiagnostics(report: InstallationReadinessReport, attachedTo window: NSWindow) {
    presentLocalDataExport(report: report, attachedTo: window)
  }

  /// Cancels only preparation and export presentation owned by the closing window.
  func cancelLocalDataExport(attachedTo window: NSWindow) {
    if localDataExportPreparationParent === window {
      localDataExportPreparationRequestID &+= 1
      localDataExportPreparationParent = nil
      checkingInstallation = false
    }
    if localDataExportParent === window { localDataExportCoordinator?.close() }
  }

}

extension ConfigurationCoordinator {
  /// Opens local data export preparation from Local Data using fresh readiness evidence.
  func localDataPaneDidRequestExport(_ pane: LocalDataPane) {
    guard !checkingInstallation, let window = localDataWindow?.window, window.attachedSheet == nil else { return }

    checkingInstallation = true
    localDataExportPreparationRequestID &+= 1
    let current = localDataExportPreparationRequestID
    localDataExportPreparationParent = window
    Task { [weak self] in
      guard let self else { return }

      let report = await installationReport()

      guard current == localDataExportPreparationRequestID, localDataExportPreparationParent === window else { return }

      checkingInstallation = false
      localDataExportPreparationParent = nil

      guard window.isVisible, window.attachedSheet == nil else {
        return
      }

      presentLocalDataExport(report: report, attachedTo: window)
    }
  }

  /// Releases only the completed flow; late closure cannot clear a replacement.
  func localDataExportCoordinatorDidClose(_ coordinator: LocalDataExportCoordinator) {
    if localDataExportCoordinator === coordinator {
      localDataExportCoordinator = nil
      localDataExportParent = nil
    }
  }

}

extension ConfigurationCoordinator {
  /// Presents a finite export flow attached to the window that requested it.
  func presentLocalDataExport(report: InstallationReadinessReport?, attachedTo window: NSWindow) {
    guard localDataExportCoordinator == nil, window.attachedSheet == nil else { return }

    let model = LocalDataExportViewModel(service: localDataExportService, readiness: report)
    let coordinator = LocalDataExportCoordinator(model: model)
    coordinator.delegate = self
    localDataExportCoordinator = coordinator
    localDataExportParent = window
    coordinator.start(attachedTo: window)
  }
}

extension ConfigurationCoordinator: CredentialSettingsDelegate {
  /// Confirms replacement while the candidate stays exclusively in the pane's secure field.
  func credentialSettings(_ sender: any CredentialSettingsSubmitting, requestReplacement state: CredentialState) {
    guard !viewModel.isBusy, let window = settingsWindow?.window, window.attachedSheet == .none else { return }
    let alert = NSAlert()
    alert.messageText = "Replace the saved TMDb token?"
    alert.informativeText = "The candidate will be tested first. The saved token changes only if testing succeeds "
      + "and credential state is still current. Collections, confirmed movie decisions, and posters are preserved."
    alert.addButton(withTitle: "Test and Replace")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak self, weak sender] response in
      guard response == .alertFirstButtonReturn, self?.settingsWindow?.window?.isVisible == true else { return }
      sender?.saveEnteredCredential(expectedState: state)
    }
  }

  /// Confirms removal against a frozen generation without changing roots or installed icons.
  func credentialSettings(_ sender: any CredentialSettingsSubmitting, requestRemoval state: CredentialState) {
    guard !viewModel.isBusy, let window = settingsWindow?.window, window.attachedSheet == .none else { return }
    let alert = NSAlert()
    alert.messageText = "Remove the saved TMDb token?"
    alert.informativeText = "Movie lookups need a token. Collections, saved movie decisions, and installed posters "
      + "remain. A changed credential will not be removed using this confirmation."
    alert.addButton(withTitle: "Remove Token")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak self, weak sender] response in
      guard response == .alertFirstButtonReturn, self?.settingsWindow?.window?.isVisible == true else { return }
      sender?.removeSavedCredential(expectedState: state)
    }
  }

  /// Opens only the fixed public setup page, never a credential-bearing URL.
  func credentialSettingsDidRequestTokenHelp(_ sender: NSViewController) {
    guard let url = URL(string: "https://www.themoviedb.org/settings/api") else { return }
    NSWorkspace.shared.open(url)
  }
}
