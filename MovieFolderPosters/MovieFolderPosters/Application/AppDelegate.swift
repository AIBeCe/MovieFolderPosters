import AppKit
import MovieFolderCommon
import OSLog

/// Presents startup failures without coupling their safe content to a modal run loop.
@MainActor
protocol AppDelegateAlertPresenting {
  /// Presents the already configured failure alert.
  /// - Parameter alert: Sanitized startup explanation owned by the caller.
  func present(_ alert: NSAlert)
  /// Obtains explicit confirmation before application records are upgraded.
  /// - Parameter alert: Explanation of migration scope and automatic backups.
  /// - Returns: Whether the user chose to migrate saved data.
  func confirmMigration(_ alert: NSAlert) -> Bool
}

extension AppDelegateAlertPresenting {
  /// Alternative presenters decline migration unless they explicitly implement confirmation.
  func confirmMigration(_ alert: NSAlert) -> Bool { false }
}

/// Uses AppKit's standard modal presentation for normal application launches.
@MainActor
struct ModalAppDelegateAlertPresenter: AppDelegateAlertPresenting {
  func present(_ alert: NSAlert) { alert.runModal() }
  func confirmMigration(_ alert: NSAlert) -> Bool { alert.runModal() == .alertFirstButtonReturn }
}

@main
/// Creates the host app's configuration flow and routes Finder poster actions.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSUserInterfaceValidations {
  /// Owns the application root independently of configuration startup success.
  private let coordinator: AppCoordinator
  /// Platform presentation boundary, independent of failure content and routing.
  private let alerts: any AppDelegateAlertPresenting
  /// Retains the application's attribution window across close and reopen.
  private var aboutWindowController: NSWindowController?
  /// Retains the user-requested operation independently of configuration windows.
  private var savedDataMigrationTask: Task<Void, Never>?

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
    configureApplicationIcon()
    do {
      try coordinator.start()
    } catch {
      presentConfigurationFailure(error)
    }
  }

  /// Applies the bundled product artwork to the Dock tile for this running application.
  private func configureApplicationIcon() {
    guard let icon = NSImage(named: "MovieFolderPostersIcon") else { return }

    NSApplication.shared.applicationIconImage = icon
  }

  /// Presents a configuration-specific failure without removing independent feature routes.
  /// - Parameters:
  ///   - error: Failure sanitized before display or logging.
  ///   - migrationStopped: Whether a manual run stopped after possibly committing earlier records.
  private func presentConfigurationFailure(_ error: Error, migrationStopped: Bool = false) {
    let alert = NSAlert()
    alert.messageText = "Saved data could not be opened"
    let failure = error as NSError
    let logger = Logger(
      subsystem: "dag.fikios.MovieFolderPosters", category: "ConfigurationStartup")
    logger.error(
      "Storage startup failed: \(failure.domain, privacy: .public), code=\(failure.code)")
    alert.informativeText =
      "The app could not read its saved settings or collection results. "
      + "Your movie folders were not changed. Open Log for details."
    if let migrationError = error as? MovieFolderStorageMigrationError {
      alert.messageText = migrationError.presentationTitle
      alert.informativeText = migrationError.localizedDescription
    }
    if let recoveryError = error as? ProcessingRecoveryError {
      alert.messageText = "Processing is blocked"
      alert.informativeText = recoveryError.localizedDescription
    }
    if let storageError = error as? CollectionProcessingStorageNamespaceError,
      storageError == .legacyMigrationRequired {
      alert.messageText = "Processing storage needs migration"
      alert.informativeText =
        "Quit older app copies and disable older Finder extension copies. "
        + "Complete the documented offline storage migration, then reopen the app."
    }
    if migrationStopped {
      alert.informativeText += " Any earlier completed upgrades were kept with their recovery copies. "
        + "After resolving this issue, run Migrate Saved Data… again to continue."
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

  /// Offers the explicit recovery action even when configuration startup has failed.
  @objc private func migrateSavedData() {
    guard savedDataMigrationTask == .none else { return }

    let confirmation = NSAlert()
    confirmation.messageText = "Migrate saved data?"
    confirmation.informativeText = "The app will back up and upgrade outdated settings and collection results. "
      + "Movie folders, poster icons and Keychain credentials are not modified."
    confirmation.addButton(withTitle: "Migrate Saved Data")
    confirmation.addButton(withTitle: "Cancel")

    guard alerts.confirmMigration(confirmation) else { return }

    savedDataMigrationTask = Task { [weak self] in
      guard let self else { return }

      defer { savedDataMigrationTask = .none }
      do {
        let report = try await coordinator.migrateSavedData()
        let result = NSAlert()
        result.messageText = report.migratedRecordCount == 0 ? "Saved data is up to date" : "Saved data upgraded"
        result.informativeText = report.completionMessage
        alerts.present(result)
        do { try coordinator.showConfiguration() } catch { presentConfigurationFailure(error) }
      } catch {
        presentConfigurationFailure(error, migrationStopped: true)
      }
    }
  }

  /// Keeps the migration action single-flight while leaving independent application routes available.
  /// - Parameter item: Menu or toolbar item being validated by AppKit.
  /// - Returns: Whether this item can currently be invoked.
  func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    item.action != #selector(migrateSavedData) || (savedDataMigrationTask == .none && !coordinator.isMigratingSavedData)
  }

  /// Presents the product's About and required TMDb attribution.
  @objc private func showAbout() {
    if let aboutWindowController {
      aboutWindowController.showWindow(.none)
      aboutWindowController.window?.makeKeyAndOrderFront(.none)
      return
    }

    let window = NSWindow(contentViewController: AboutViewController())
    window.title = "About Movie Folder Posters"
    window.styleMask = [.titled, .closable]
    window.setContentSize(NSSize(width: 640, height: 400))
    window.isReleasedWhenClosed = false
    window.center()
    aboutWindowController = NSWindowController(window: window)
    aboutWindowController?.showWindow(.none)
  }

  /// Refreshes committed outcome projections when the host returns to the foreground.
  func applicationDidBecomeActive(_ notification: Notification) { coordinator.applicationDidBecomeActive() }

  /// Opens a poster action for each valid action URL passed to the app.
  ///
  /// - Parameters:
  ///   - application: The application receiving the URLs.
  ///   - urls: URLs requested by the system or another app.
  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      if let request = try? MovieFolderInclusionRequest(url: url) {
        coordinator.openInclusionAction(request)
        continue
      }
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
      action: #selector(showAbout), keyEquivalent: "").target = self
    applicationMenu.addItem(.separator())
    applicationMenu.addItem(
      withTitle: "Quit Movie Folder Posters", action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    applicationItem.submenu = applicationMenu
    let editItem = NSMenuItem(title: "Edit", action: .none, keyEquivalent: "")
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(
      withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    applicationMenu.insertItem(
      withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",", at: 1).target = self
    applicationMenu.insertItem(
      withTitle: "Migrate Saved Data…", action: #selector(migrateSavedData), keyEquivalent: "", at: 2).target = self
    let windowItem = NSMenuItem(title: "Window", action: .none, keyEquivalent: "")
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

/// Presents product identity prominently with compact required TMDb attribution.
@MainActor
final class AboutViewController: NSViewController {
  /// The notice TMDb requires applications to display prominently.
  static let requiredNotice = "This product uses the TMDB API but is not endorsed or certified by TMDB."

  /// Storyboard and archive construction are unsupported; create this view programmatically.
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  /// Creates an attribution view without storyboard or archive construction.
  init() { super.init(nibName: .none, bundle: .none) }

  /// Builds an accessible product-first About view with a compact TMDb attribution footer.
  override func loadView() {
    let appIcon = makeProductIcon()
    let hero = makeProductHero(icon: appIcon)
    let (divider, attribution) = makeAttributionSection()
    let stack = NSStackView(views: [hero, divider, attribution])
    stack.orientation = NSUserInterfaceLayoutOrientation.vertical
    stack.alignment = NSLayoutConstraint.Attribute.leading
    stack.spacing = 24
    stack.translatesAutoresizingMaskIntoConstraints = false
    view = NSView()
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
      stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      appIcon.widthAnchor.constraint(equalToConstant: 148),
      appIcon.heightAnchor.constraint(equalToConstant: 148),
      divider.widthAnchor.constraint(equalTo: stack.widthAnchor)
    ])
  }

  /// Creates the icon view using the product artwork from the asset catalog.
  private func makeProductIcon() -> NSImageView {
    let image = NSImage(named: "MovieFolderPostersIcon")
      ?? NSApplication.shared.applicationIconImage
      ?? NSImage(size: NSSize(width: 148, height: 148))
    let icon = NSImageView(image: image)
    icon.imageScaling = NSImageScaling.scaleProportionallyUpOrDown
    icon.wantsLayer = true
    icon.layer?.cornerRadius = 24
    icon.layer?.cornerCurve = .continuous
    icon.layer?.masksToBounds = true
    icon.setAccessibilityLabel("Movie Folder Posters app icon")
    icon.setAccessibilityIdentifier("MovieFolderPostersAppIcon")

    return icon
  }

  /// Creates the product icon and identity row.
  private func makeProductHero(icon: NSImageView) -> NSStackView {
    let heading = NSTextField(labelWithString: "Movie Folder Posters")
    heading.font = .systemFont(ofSize: 27, weight: .semibold)
    heading.setAccessibilityIdentifier("AboutProductName")
    let tagline = NSTextField(labelWithString: "Movie artwork, right where you browse.")
    tagline.font = .systemFont(ofSize: 15)
    tagline.textColor = .secondaryLabelColor
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    let versionLabel = NSTextField(labelWithString: version.isEmpty ? "" : "Version \(version)")
    versionLabel.font = .systemFont(ofSize: 12)
    versionLabel.textColor = .tertiaryLabelColor

    let details = NSStackView(views: [heading, tagline, versionLabel])
    details.orientation = NSUserInterfaceLayoutOrientation.vertical
    details.alignment = NSLayoutConstraint.Attribute.leading
    details.spacing = 8
    let hero = NSStackView(views: [icon, details])
    hero.orientation = NSUserInterfaceLayoutOrientation.horizontal
    hero.alignment = NSLayoutConstraint.Attribute.centerY
    hero.spacing = 28

    return hero
  }

  /// Creates the divider and compact TMDb attribution section.
  private func makeAttributionSection() -> (NSBox, NSStackView) {
    let divider = NSBox()
    divider.boxType = .separator
    let notice = NSTextField(wrappingLabelWithString: Self.requiredNotice)
    notice.font = .systemFont(ofSize: 12)
    notice.textColor = .secondaryLabelColor
    notice.setAccessibilityIdentifier("TMDbAttributionNotice")
    let image = NSImage(named: "TMDbLogo") ?? NSImage(size: NSSize(width: 88, height: 38))
    let logo = NSImageView(image: image)
    logo.imageScaling = NSImageScaling.scaleProportionallyUpOrDown
    logo.setAccessibilityLabel("TMDb logo")
    logo.setAccessibilityIdentifier("TMDbLogo")
    let link = NSButton(title: "Visit TMDB", target: self, action: #selector(openTMDb))
    link.bezelStyle = .rounded
    link.setAccessibilityLabel("Visit The Movie Database website")
    link.setAccessibilityIdentifier("TMDbWebsiteLink")

    let details = NSStackView(views: [notice, link])
    details.orientation = NSUserInterfaceLayoutOrientation.vertical
    details.alignment = NSLayoutConstraint.Attribute.leading
    details.spacing = 8
    let section = NSStackView(views: [logo, details])
    section.orientation = NSUserInterfaceLayoutOrientation.horizontal
    section.alignment = NSLayoutConstraint.Attribute.centerY
    section.spacing = 18
    NSLayoutConstraint.activate([
      logo.widthAnchor.constraint(equalToConstant: 88),
      logo.heightAnchor.constraint(equalToConstant: 38)
    ])

    return (divider, section)
  }

  /// Opens TMDb's canonical website.
  @objc private func openTMDb() {
    guard let url = URL(string: "https://www.themoviedb.org") else { return }

    NSWorkspace.shared.open(url)
  }
}
