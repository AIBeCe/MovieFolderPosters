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
  CollectionResultsViewControllerDelegate, NSWindowDelegate {
  /// Root router; the root retains this child for its flow lifetime.
  weak var delegate: (any ConfigurationCoordinatorDelegate)?
  /// Supplies configuration state and operations to the host's views.
  private let viewModel: ConfigurationViewModel
  /// Retains the persistence boundary for confirmed Finder inclusion actions.
  private let service: any ConfigurationServicing
  /// Independently reads committed processing snapshots for main-window presentation.
  private let summaryViewModel: CollectionSummaryViewModel
  /// Shared appearance selection owned and applied by the application root.
  private let appearance: AppAppearanceSettings
  /// The main configuration window, when it has been created.
  private(set) var mainWindow: NSWindowController?
  /// The settings window, when it has been created.
  private(set) var settingsWindow: NSWindowController?
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
  /// Results presentation retained until explicit dismissal or parent closure.
  private(set) var resultsWindow: NSWindow?
  /// Owns selected retry lifetime independently of view rendering.
  private var resultsViewModel: CollectionResultsViewModel?
  /// Finite setup sheet retained independently from Settings and result sheets.
  private(set) var setupWindow: NSWindow?
  /// Uncommitted bookmarks and local choices, discarded with the setup sheet.
  private var setupViewModel: CollectionSetupViewModel?
  /// Retains the finite collection edit sheet until cancellation or a successful atomic save.
  private var editWindow: NSWindow?
  /// Draft and compare-and-swap evidence owned by the edit flow.
  private var editViewModel: CollectionEditViewModel?

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
    retryService: any CollectionRetryServicing = UnavailableCollectionRetryService()
  ) {
    self.service = service
    self.installationService = installationService
    self.activity = activity
    self.appearance = appearance
    self.retryService = retryService
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

  /// Observes shared invalidations while either Main or Settings uses this retained flow.
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
      collectionName: directory.effectiveDisplayName,
      summary: summary)
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
  }

  /// Ends the processing-details sheet when its Close action or parent window dismisses it.
  private func closeDetails() {
    guard let sheet = detailsWindow else { return }
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
    let model = CollectionResultsViewModel(rootID: rootID, summaries: summaryViewModel, retryService: retryService)
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
      if settingsWindow?.window?.isVisible != true {
        DistributedNotificationCenter.default().removeObserver(self)
        isObservingProcessing = false
      }
      window.delegate = .none
      closeDetails()
      closeResults()
      closeSetup()
      closeEdit()
    } else if window === settingsWindow?.window {
      viewModel.cancelCredentialAction()
      if mainWindow?.window?.isVisible != true {
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

  /// Presents focused unresolved results for a configured collection.
  func configurationViewControllerDidRequestUnresolvedResults(_ controller: ConfigurationViewController, rootID: UUID) {
    showUnresolvedResults(rootID: rootID)
  }

  /// Invalidates captured selection after authorization or processing configuration changes.
  @objc private func resultsConfigurationChanged(_ notification: Notification) {
    Task { @MainActor [weak self] in
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

extension ConfigurationCoordinator {
  /// Confirms the captured Finder action before its identity and revision are revalidated by the service.
  func openInclusionAction(_ request: MovieFolderInclusionRequest) {
    start()

    guard let parent = mainWindow?.window, parent.attachedSheet == .none else { return }

    let alert = NSAlert()
    let includes = request.action == .include
    alert.messageText = includes ? "Include Folder?" : "Ignore Folder?"
    alert.informativeText = request.folderURL.lastPathComponent
      + (includes ? " will participate when the collection is active." : " will be excluded from processing.")
      + " Existing posters and movie contents are preserved."
    alert.addButton(withTitle: includes ? "Include Folder" : "Ignore Folder")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: parent) { [weak self] response in
      guard response == .alertFirstButtonReturn, let self else { return }

      Task {
        do { try await service.applyInclusionRequest(request) }
        catch {
          let failure = NSAlert()
          failure.messageText = "Could not change folder inclusion"
          failure.informativeText = "The folder or collection may have changed. Open the Finder menu and try again."
          _ = await failure.beginSheetModal(for: parent)
        }
        await viewModel.load()
        summaryViewModel.reload()
      }
    }
  }

  /// Refreshes friendly names without invalidating captured processing or unresolved selection.
  /// - Parameter notification: Payload-free presentation invalidation from a committed collection rename.
  @objc private func collectionPresentationChanged(_ notification: Notification) {
    Task { @MainActor [weak self] in await self?.viewModel.load() }
  }

  /// Owns folder selection and applies only a confirmed selection through the configuration model.
  func configurationViewController(
    _ controller: ConfigurationViewController, didRequestDirectorySelection identifier: UUID?
  ) {
    guard !viewModel.isBusy, let window = mainWindow?.window, window.attachedSheet == .none else { return }

    guard let identifier else { showCollectionSetup(); return }

    let panel = NSOpenPanel()
    panel.title = "Restore Folder Access"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      Task {
        await self.viewModel.reauthorizeDirectory(identifier, with: url)
      }
    }
  }

  /// Opens the same finite setup sheet with the validated Main drop prepared in memory.
  func configurationViewController(_ controller: ConfigurationViewController, didDrop directory: URL) {
    showCollectionSetup(preparing: directory)
  }

  /// Owns the native rename prompt while the model and service own presentation state and persistence.
  func configurationViewController(_ controller: ConfigurationViewController, didRequestRename identifier: UUID) {
    guard !viewModel.isBusy, let window = mainWindow?.window, window.attachedSheet == .none else { return }

    let model = viewModel.makeCollectionEditViewModel(identifier: identifier)
    let controller = CollectionEditViewController(viewModel: model)
    controller.delegate = self
    let sheet = NSWindow(contentViewController: controller)
    sheet.title = "Edit Collection"
    sheet.styleMask = [.titled, .closable, .resizable]
    sheet.setContentSize(NSSize(width: 580, height: 600))
    sheet.delegate = self
    editWindow = sheet
    editViewModel = model
    window.beginSheet(sheet)
    Task { await model.load() }
  }

  /// Discards the draft only when no final save is running.
  private func closeEdit() {
    guard let sheet = editWindow, editViewModel?.isBusy != true else { return }

    editWindow = .none
    editViewModel = .none
    if let parent = sheet.sheetParent { parent.endSheet(sheet) }
    sheet.delegate = .none
    sheet.close()
  }

  /// Keeps a final commit alive until its result is known before either owning window can close.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if sender === editWindow || sender === mainWindow?.window, editViewModel?.isBusy == true { return false }
    if sender === setupWindow || sender === mainWindow?.window { return setupViewModel?.isCommitting != true }

    return true
  }

  /// Starts one native sheet, initially without a folder unless Main supplied a valid drop.
  /// - Parameter directory: Optional validated Main drop to prepare after the empty setup sheet is created.
  private func showCollectionSetup(preparing directory: URL? = .none) {
    guard !viewModel.isBusy, let parent = mainWindow?.window, parent.attachedSheet == .none else { return }

    let model = viewModel.makeCollectionSetupViewModel()
    let controller = CollectionSetupViewController(viewModel: model)
    controller.delegate = self
    let sheet = NSWindow(contentViewController: controller)
    sheet.title = "Add Collection"
    sheet.styleMask = [.titled, .closable]
    sheet.setContentSize(NSSize(width: 580, height: 620))
    sheet.delegate = self
    setupWindow = sheet
    setupViewModel = model
    parent.beginSheet(sheet)
    if let directory { Task { await model.prepare(directory) } }
  }

  /// Discards the candidate and ends only the setup flow's own sheet.
  private func closeSetup() {
    guard let sheet = setupWindow, setupViewModel?.isCommitting != true else { return }

    setupViewModel?.cancel()
    setupViewModel = .none
    setupWindow = .none
    if let parent = sheet.sheetParent { parent.endSheet(sheet) }
    sheet.delegate = .none
    sheet.close()
  }
}

extension ConfigurationCoordinator: CollectionEditViewControllerDelegate {
  /// Keeps the draft visible after a conflict and refreshes Main after a successful save.
  func collectionEditViewControllerDidRequestSave(_ controller: CollectionEditViewController) {
    guard let model = editViewModel, model.canSave else { return }

    Task {
      if await model.save() {
        closeEdit()
        await viewModel.load()
        summaryViewModel.reload()
      }
    }
  }
  /// Discards every local change.
  func collectionEditViewControllerDidRequestCancel(_ controller: CollectionEditViewController) { closeEdit() }
}

extension ConfigurationCoordinator: CollectionSetupViewControllerDelegate {
  /// Uses the existing authorization panel while the chosen folder is still security scoped.
  func collectionSetupViewControllerDidRequestFolder(_ controller: CollectionSetupViewController) {
    guard let sheet = setupWindow, sheet.attachedSheet == .none, let model = setupViewModel,
      !model.isBusy else { return }

    let panel = NSOpenPanel()
    panel.title = "Choose Movie Collection Folder"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.beginSheetModal(for: sheet) { response in
      guard response == .OK, let directory = panel.url else { return }

      Task { await model.prepare(directory) }
    }
  }

  /// Prepares a replacement drop through the same bookmark and validation service as Choose.
  func collectionSetupViewController(_ controller: CollectionSetupViewController, didDrop directory: URL) {
    guard let model = setupViewModel, !model.isBusy else { return }

    Task { await model.prepare(directory) }
  }

  /// Commits only after explicit Add, preserving the sheet and corrective message if persistence fails.
  func collectionSetupViewControllerDidRequestAdd(_ controller: CollectionSetupViewController) {
    guard let model = setupViewModel, model.canAdd else { return }

    Task {
      if await model.commit() {
        closeSetup()
        await viewModel.load()
        summaryViewModel.reload()
      }
    }
  }

  /// Cancels the finite draft without a configuration notification or preference write.
  func collectionSetupViewControllerDidRequestCancel(_ controller: CollectionSetupViewController) { closeSetup() }
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

  /// Lets the user choose a destination before reading retained activity or writing a diagnostic file.
  /// - Parameters:
  ///   - report: The readiness snapshot projected through the export's fixed status vocabulary.
  ///   - window: The configuration window that owns the save panel and any sanitized failure alert.
  func exportDiagnostics(report: InstallationReadinessReport, attachedTo window: NSWindow) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = "MovieFolderPosters-Diagnostics.txt"
    panel.title = "Export Diagnostics"
    panel.message = "Exports readiness statuses and up to 50 recent activity timestamps and actions. "
      + "Folder paths, credentials, identifiers, and error details are excluded."
    panel.beginSheetModal(for: window) { response in
      guard response == .OK, let destination = panel.url else { return }

      Task {
        let entries = try? await self.activity.entries()
        let text = InstallationDiagnosticsExport.format(report: report, entries: entries)
        do {
          try await Task.detached(priority: .utility) {
            try text.write(to: destination, atomically: true, encoding: .utf8)
          }.value
        } catch {
          guard window.isVisible, window.attachedSheet == .none else { return }

          let alert = NSAlert()
          alert.messageText = "Diagnostics could not be saved"
          alert.informativeText = "Choose another destination and try again. Error details are excluded."
          _ = await alert.beginSheetModal(for: window)
        }
      }
    }
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
