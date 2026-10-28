import AppKit
import UniformTypeIdentifiers

/// Notifies the configuration owner when its finite child is dismissed.
@MainActor
protocol LocalDataExportCoordinatorDelegate: AnyObject {
  /// Releases the completed local data export flow.
  /// - Parameter coordinator: The child export coordinator that closed.
  func localDataExportCoordinatorDidClose(_ coordinator: LocalDataExportCoordinator)
}

/// Owns one local data export sheet, preview and save destination lifetime.
@MainActor
final class LocalDataExportCoordinator: NSObject, LocalDataExportViewControllerDelegate, NSWindowDelegate {
  /// Owner retains this coordinator until dismissal.
  weak var delegate: (any LocalDataExportCoordinatorDelegate)?
  /// Finite presentation and source state.
  private let model: LocalDataExportViewModel
  /// Sheet retained independently of AppKit's weak delegates.
  private var sheet: NSWindow?
  /// Owns staged writes and the same-actor cancellation/publication gate.
  private let exportWriter: LocalDataExportWriter
  /// Pending finite save, cancelled when the owner closes.
  private var saveTask: Task<Void, Never>?
  /// Fences delayed save-panel and evidence responses.
  private var generation = UInt64.zero

  /// Creates one finite read-only preparation flow.
  /// - Parameter model: Selection and preview state retained for this sheet.
  init(model: LocalDataExportViewModel) {
    self.model = model
    exportWriter = LocalDataExportWriter(model: model)
    super.init()
  }

  /// Presents explicit selection before any destination or file write.
  /// - Parameter parent: Window that owns this export sheet.
  func start(attachedTo parent: NSWindow) {
    guard parent.attachedSheet == nil else { return }

    let controller = LocalDataExportViewController(model: model)
    controller.delegate = self
    let window = NSWindow(contentViewController: controller)
    window.title = "Local Data Export"
    window.styleMask = [.titled, .closable, .resizable]
    window.setContentSize(NSSize(width: 840, height: 650))
    window.minSize = NSSize(width: 780, height: 600)
    window.delegate = self
    sheet = window
    parent.beginSheet(window)
  }

  /// Invalidates late work before ending this sheet and any nested save panel.
  func close() {
    generation &+= 1
    exportWriter.close()
    model.close()
    saveTask?.cancel()
    saveTask = nil

    guard let window = sheet else { return }

    (window.contentViewController as? LocalDataExportViewController)?.cancelPendingWork()
    sheet = nil
    if let child = window.attachedSheet {
      window.endSheet(child, returnCode: .cancel)
      child.close()
    }
    if let parent = window.sheetParent { parent.endSheet(window) }
    window.delegate = nil
    window.close()
    delegate?.localDataExportCoordinatorDidClose(self)
  }

  func windowWillClose(_ notification: Notification) { close() }
  func localDataExportViewControllerDidRequestClose(_ controller: LocalDataExportViewController) { close() }
  func localDataExportViewControllerDidRequestSave(_ controller: LocalDataExportViewController) {
    guard saveTask == nil, let window = sheet, window.attachedSheet == nil, model.preview != nil else { return }

    let current = generation
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "MovieFolderPosters-LocalData.json"
    panel.title = "Save Local Data Export"
    panel.beginSheetModal(for: window) { [weak self, weak controller] response in
      guard let self, let controller, response == .OK, let destination = panel.url,
        current == generation, sheet === window
      else { return }

      saveTask = Task { [weak self, weak controller] in
        guard let self else { return }

        do {
          guard current == generation, sheet === window, window.isVisible else {
            saveTask = nil
            return
          }

          try await exportWriter.save(to: destination)

          guard current == generation, sheet === window else { return }

          saveTask = nil
          close()
        } catch {
          guard current == generation, sheet === window else { return }

          saveTask = nil
          controller?.showSaveFailure()
        }
      }
    }
  }
}
