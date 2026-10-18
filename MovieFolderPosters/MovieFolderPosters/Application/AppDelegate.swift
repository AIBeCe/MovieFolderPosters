import AppKit
import MovieFolderCommon
import OSLog

/// Presents startup failures without coupling their safe content to a modal run loop.
@MainActor
protocol AppDelegateAlertPresenting {
  /// Presents the already configured failure alert.
  /// - Parameter alert: Sanitized startup explanation owned by the caller.
  func present(_ alert: NSAlert)
}

/// Uses AppKit's standard modal presentation for normal application launches.
@MainActor
struct ModalAppDelegateAlertPresenter: AppDelegateAlertPresenting {
  func present(_ alert: NSAlert) { alert.runModal() }
}

@main
/// Creates the host app's configuration flow and routes Finder poster actions.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  /// Owns the application root independently of configuration startup success.
  private let coordinator: AppCoordinator
  /// Platform presentation boundary, independent of failure content and routing.
  private let alerts: any AppDelegateAlertPresenting

  /// Builds the live root for AppKit's normal launch path.
  override convenience init() { self.init(coordinator: AppCoordinator()) }

  /// Retains the application root before any lifecycle event is delivered.
  /// - Parameters:
  ///   - coordinator: Root owning the configured host flows.
  ///   - alerts: Platform presenter for sanitized startup failures.
  init(coordinator: AppCoordinator, alerts: any AppDelegateAlertPresenting = ModalAppDelegateAlertPresenter()) {
    self.coordinator = coordinator
    self.alerts = alerts
    super.init()
  }

  /// Starts the AppKit application with this delegate retained through the run loop.
  static func main() {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
    withExtendedLifetime(delegate) {}
  }

  /// Installs the app menu and opens the configuration window after launch.
  ///
  /// - Parameter notification: The launch notification supplied by AppKit.
  func applicationDidFinishLaunching(_ notification: Notification) {
    installMenu()
    do {
      try coordinator.start()
    } catch {
      presentConfigurationFailure(error)
    }
  }

  /// Presents a configuration-specific failure without removing independent feature routes.
  /// - Parameter error: Startup failure sanitized before display or logging.
  private func presentConfigurationFailure(_ error: Error) {
    let alert = NSAlert()
    alert.messageText = "Configuration storage is unavailable"
    let failure = error as NSError
    let logger = Logger(
      subsystem: "dag.fikios.MovieFolderPosters", category: "ConfigurationStartup")
    logger.error(
      "Storage startup failed: \(failure.domain, privacy: .public), code=\(failure.code)")
    alert.informativeText =
      "The app could not open its settings. Quit and reopen it using a signed build."
    if let storageError = error as? CollectionProcessingStorageNamespaceError,
      storageError == .legacyMigrationRequired {
      alert.messageText = "Processing storage needs migration"
      alert.informativeText =
        "Quit older app copies and disable older Finder extension copies. "
        + "Complete the documented offline storage migration, then reopen the app."
    }
    alerts.present(alert)
  }

  /// Reopens configuration from an app event or the Window menu.
  @objc private func showConfiguration() {
    do { try coordinator.showConfiguration() } catch { presentConfigurationFailure(error) }
  }

  /// Opens Settings through the root's configuration route.
  @objc private func showSettings() {
    do { try coordinator.showSettings() } catch { presentConfigurationFailure(error) }
  }

  /// Opens Log even if configuration storage could not initialize.
  @objc private func showLog() { coordinator.showLog() }

  /// Refreshes committed outcome projections when the host returns to the foreground.
  func applicationDidBecomeActive(_ notification: Notification) {
    coordinator.applicationDidBecomeActive()
  }

  /// Opens a poster action for each valid action URL passed to the app.
  ///
  /// - Parameters:
  ///   - application: The application receiving the URLs.
  ///   - urls: URLs requested by the system or another app.
  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      guard let request = try? MoviePosterRequest(url: url) else { continue }
      coordinator.openPosterAction(request)
    }
  }

  /// Brings the configuration window forward when the app is reopened.
  ///
  /// - Parameters:
  ///   - sender: The application requesting the reopen behavior.
  ///   - flag: Whether any app windows are currently visible.
  /// - Returns: `true` to allow the app to handle the reopen event.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showConfiguration()

    return true
  }

  /// Enables AppKit's secure state restoration support.
  ///
  /// - Parameter app: The application requesting restoration support.
  /// - Returns: `true` to permit secure restorable state.
  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

  /// Builds the standard application and Edit menus.
  private func installMenu() {
    let menu = NSMenu()
    let applicationItem = NSMenuItem()
    menu.addItem(applicationItem)
    let applicationMenu = NSMenu()
    applicationMenu.addItem(
      withTitle: "About Movie Folder Posters",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    applicationMenu.addItem(.separator())
    applicationMenu.addItem(
      withTitle: "Quit Movie Folder Posters", action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    applicationItem.submenu = applicationMenu
    let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(
      withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    applicationMenu.insertItem(
      withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",", at: 1).target = self
    let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(withTitle: "Movie Folder Posters", action: #selector(showConfiguration), keyEquivalent: "")
      .target = self
    windowMenu.addItem(withTitle: "Log", action: #selector(showLog), keyEquivalent: "").target = self
    windowItem.submenu = windowMenu
    editItem.submenu = editMenu
    menu.addItem(editItem)
    menu.addItem(windowItem)
    NSApplication.shared.mainMenu = menu
  }
}
