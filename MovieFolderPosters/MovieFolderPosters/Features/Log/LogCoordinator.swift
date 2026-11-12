import AppKit
import Common

/// Owns reusable operational history presentation and its committed-activity subscription.
@MainActor
final class LogCoordinator: NSObject, LogViewControllerDelegate {
  /// Retains the window across close/reopen without retaining sibling flows.
  private(set) var windowController: NSWindowController?
  /// Owns the auxiliary evidence window independently of its rendering controller.
  private(set) var matchingDetailsWindowController: NSWindowController?
  /// Identity and immutable text currently presented in the evidence window.
  private var presentedMatchingDetails: LogViewModel.MatchingDetails?
  /// Presents history from the independent activity service.
  private let viewModel: LogViewModel
  /// Prevents duplicate registrations after repeated presentation.
  private var isObservingActivity = false

  /// Creates state without loading history or opening a window.
  /// - Parameters:
  ///   - activityHistoryService: Activity history shared with product event producers.
  ///   - networkHistoryService: Optional network history and its persisted recording preference.
  init(
    activityHistoryService: any ActivityLogPresentationServices,
    networkHistoryService: (any NetworkLogPresentationServices)? = .none
  ) {
    viewModel = LogViewModel(activityHistoryService: activityHistoryService,
      networkHistoryService: networkHistoryService)
    super.init()
  }

  deinit { DistributedNotificationCenter.default().removeObserver(self) }

  /// Presents the single reusable window and reloads committed history.
  func show() {
    if !isObservingActivity {
      DistributedNotificationCenter.default().addObserver(
        self, selector: #selector(activityChanged(_:)), name: .movieFolderActivityChanged, object: .none)
      for name in [Notification.Name.movieFolderNetworkHistoryChanged, .movieFolderHistoryConfigurationChanged] {
        DistributedNotificationCenter.default().addObserver(
          self, selector: #selector(activityChanged(_:)), name: name, object: .none)
      }
      isObservingActivity = true
    }
    if windowController == .none {
      let controller = LogViewController(viewModel: viewModel)
      controller.delegate = self
      let window = NSWindow(contentViewController: controller)
      window.title = "Log — Movie Folder Posters"
      window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
      window.setContentSize(NSSize(width: 820, height: 460))
      window.minSize = NSSize(width: 650, height: 380)
      window.isReleasedWhenClosed = false
      window.center()
      windowController = NSWindowController(window: window)
    }
    viewModel.requestReload()
    windowController?.showWindow(.none)
    windowController?.window?.makeKeyAndOrderFront(.none)
  }

  /// Constructs and retains native read-only evidence presentation for a current selection.
  func logViewController(
    _ controller: LogViewController, didRequestMatchingDetails details: LogViewModel.MatchingDetails
  ) {
    guard details == viewModel.selectedMatchingDetails else { return }

    if presentedMatchingDetails != details {
      matchingDetailsWindowController?.close()
      let window = NSWindow(contentViewController: MatchingDetailsViewController(text: details.text))
      window.title = "Matching Details — Movie Folder Posters"
      window.styleMask = [.titled, .closable, .resizable]
      window.setContentSize(NSSize(width: 640, height: 480))
      window.minSize = NSSize(width: 420, height: 280)
      window.isReleasedWhenClosed = false
      window.center()
      matchingDetailsWindowController = NSWindowController(window: window)
      presentedMatchingDetails = details
    }
    matchingDetailsWindowController?.showWindow(.none)
    matchingDetailsWindowController?.window?.makeKeyAndOrderFront(.none)
  }

  /// Dismisses obsolete evidence immediately when selection, source, filtering, or Clear invalidates it.
  func logViewController(
    _ controller: LogViewController, didSelectMatchingDetails details: LogViewModel.MatchingDetails?
  ) {
    guard presentedMatchingDetails != details else { return }

    matchingDetailsWindowController?.close()
    matchingDetailsWindowController = .none
    presentedMatchingDetails = .none
  }

  /// Refreshes an existing projection without creating a hidden window.
  func applicationDidBecomeActive() {
    if windowController != .none { viewModel.requestReload() }
  }

  /// Preserves process-local failed-write evidence when no successful-append notification can be posted.
  /// - Parameter saved: Whether a producer committed its activity entry.
  func producerDidRecord(saved: Bool) { viewModel.producerDidRecord(saved: saved) }

  /// Invalidates presentation; persisted entries remain authoritative.
  @objc private func activityChanged(_ notification: Notification) {
    Task { @MainActor [weak self] in self?.viewModel.requestReload() }
  }
}
