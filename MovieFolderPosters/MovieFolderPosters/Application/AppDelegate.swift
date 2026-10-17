import AppKit
import OSLog

@main
/// Creates the host app's configuration flow and routes Finder poster actions.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  /// Owns the configuration windows for the lifetime of the app delegate.
  private var coordinator: ConfigurationCoordinator?
  /// Presents poster actions opened through the app's URL handler.
  private let posterActions = MoviePosterActionCoordinator()

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
      let service = try DirectoryConfigurationService(
        repository: SharedEnvironment.repository(),
        authorizations: SharedEnvironment.privateAuthorizations())
      #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--development-fixtures") {
          Task { try? await service.setDevelopmentFixtures(true) }
        } else if ProcessInfo.processInfo.arguments.contains("--disable-development-fixtures") {
          Task { try? await service.setDevelopmentFixtures(false) }
        }
      #endif
      coordinator = ConfigurationCoordinator(service: service)
      coordinator?.start()
    } catch {
      let alert = NSAlert()
      alert.messageText = "Configuration storage is unavailable"
      let failure = error as NSError
      let logger = Logger(
        subsystem: "dag.fikios.MovieFolderPosters", category: "ConfigurationStartup")
      logger.error(
        "Storage startup failed: \(failure.domain, privacy: .public), code=\(failure.code)")
      alert.informativeText =
        "The app could not open its settings. Quit and reopen it using a signed build."
      alert.runModal()
    }
  }

  /// Opens a poster action for each valid action URL passed to the app.
  ///
  /// - Parameters:
  ///   - application: The application receiving the URLs.
  ///   - urls: URLs requested by the system or another app.
  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      guard let request = try? MoviePosterRequest(url: url) else { continue }
      posterActions.start(request)
    }
  }

  /// Brings the configuration window forward when the app is reopened.
  ///
  /// - Parameters:
  ///   - sender: The application requesting the reopen behavior.
  ///   - flag: Whether any app windows are currently visible.
  /// - Returns: `true` to allow the app to handle the reopen event.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    coordinator?.start()

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
    editItem.submenu = editMenu
    menu.addItem(editItem)
    NSApplication.shared.mainMenu = menu
  }
}
