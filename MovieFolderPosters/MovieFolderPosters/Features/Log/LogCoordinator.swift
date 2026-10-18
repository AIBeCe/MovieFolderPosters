import AppKit
import MovieFolderCommon

/// Owns reusable operational history presentation and its committed-activity subscription.
@MainActor
final class LogCoordinator: NSObject {
  /// Retains the window across close/reopen without retaining sibling flows.
  private(set) var windowController: NSWindowController?
  /// Presents history from the independent activity service.
  private let viewModel: ActivityLogViewModel
  /// Prevents duplicate registrations after repeated presentation.
  private var isObservingActivity = false

  /// Creates state without loading history or opening a window.
  /// - Parameter activity: History service shared with product event producers.
  init(activity: any MovieFolderActivityServicing) {
    viewModel = ActivityLogViewModel(service: activity)
    super.init()
  }

  deinit { DistributedNotificationCenter.default().removeObserver(self) }

  /// Presents the single reusable window and reloads committed history.
  func show() {
    if !isObservingActivity {
      DistributedNotificationCenter.default().addObserver(
        self, selector: #selector(activityChanged(_:)), name: MovieFolderEnvironment.activityChanged, object: nil)
      isObservingActivity = true
    }
    if windowController == nil {
      let window = NSWindow(contentViewController: LogViewController(log: viewModel))
      window.title = "Log — Movie Folder Posters"
      window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
      window.setContentSize(NSSize(width: 820, height: 360))
      window.minSize = NSSize(width: 650, height: 280)
      window.isReleasedWhenClosed = false
      window.center()
      windowController = NSWindowController(window: window)
    }
    viewModel.requestReload()
    windowController?.showWindow(nil)
    windowController?.window?.makeKeyAndOrderFront(nil)
  }

  /// Refreshes an existing projection without creating a hidden window.
  func applicationDidBecomeActive() {
    if windowController != nil { viewModel.requestReload() }
  }

  /// Preserves process-local failed-write evidence when no successful-append notification can be posted.
  /// - Parameter saved: Whether a producer committed its activity entry.
  func producerDidRecord(saved: Bool) { viewModel.producerDidRecord(saved: saved) }

  /// Invalidates presentation; persisted entries remain authoritative.
  @objc private func activityChanged(_ notification: Notification) {
    Task { @MainActor [weak self] in self?.viewModel.requestReload() }
  }
}
