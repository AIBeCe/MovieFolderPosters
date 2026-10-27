import AppKit
import MovieFolderCommon

extension ConfigurationCoordinator {
  /// Confirms the captured Finder action before its identity and revision are revalidated by the service.
  func openInclusionAction(_ request: MovieFolderInclusionRequest) {
    start()

    guard let parent = mainWindow?.window, parent.attachedSheet == .none else { return }

    let alert = NSAlert()
    let includes = request.action == .include
    alert.messageText = includes ? "Include Folder?" : "Ignore Folder?"
    alert.informativeText = request.folderURL.lastPathComponent
      + (includes ? " will be included when the collection is active." : " will be excluded from processing.")
      + " Existing posters and movie contents are preserved."
    alert.addButton(withTitle: includes ? "Include Folder" : "Ignore Folder")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: parent) { [weak self] response in
      guard response == .alertFirstButtonReturn, let self else { return }

      Task {
        do { try await service.applyInclusionRequest(request) } catch {
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
  @objc func collectionPresentationChanged(_ notification: Notification) {
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
    sheet.setContentSize(NSSize(width: 580, height: 620))
    sheet.delegate = self
    editWindow = sheet
    editViewModel = model
    window.beginSheet(sheet)
    Task { await model.load() }
  }

  /// Discards the draft only when no final save is running.
  func closeEdit() {
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
  fileprivate func showCollectionSetup(preparing directory: URL? = .none) {
    guard !viewModel.isBusy, let parent = mainWindow?.window, parent.attachedSheet == .none else { return }

    let model = viewModel.makeCollectionSetupViewModel()
    let controller = CollectionSetupViewController(viewModel: model)
    controller.delegate = self
    let sheet = NSWindow(contentViewController: controller)
    sheet.title = "Add Collection"
    sheet.styleMask = [.titled, .closable, .resizable]
    sheet.setContentSize(NSSize(width: 580, height: 620))
    sheet.delegate = self
    setupWindow = sheet
    setupViewModel = model
    parent.beginSheet(sheet)
    if let directory { Task { await model.prepare(directory) } }
  }

  /// Discards the candidate and ends only the setup flow's own sheet.
  func closeSetup() {
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
